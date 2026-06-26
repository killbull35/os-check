#!/usr/bin/env bash
# ==============================================================================
# Diagnostic shards a risque avant maintenance OpenSearch
# Decouverte des noeuds via _nodes?filter_path + attributs custom zone/temp
# Shell pur - aucune dependance externe (pas de jq, pas de python)
#
# Usage:
#   ./os_risk_diag.sh [host:port] [--temp hot|warm|cold] [--zone az1|az2|az3]
#                     [--no-cache] [--resume] [--log-dir /chemin]
#
# Exemples:
#   ./os_risk_diag.sh
#   ./os_risk_diag.sh localhost:9200 --temp warm
#   ./os_risk_diag.sh localhost:9200 --zone az2
#   ./os_risk_diag.sh localhost:9200 --temp hot --zone az1 --no-cache
#   ./os_risk_diag.sh localhost:9200 --resume
# ==============================================================================
export LC_ALL=C
export LANG=C

# ------------------------------------------------------------------------------
# Charger la configuration depuis .env
# ------------------------------------------------------------------------------
ENV_FILE=".env"
if [ -f "$ENV_FILE" ]; then
    # Charger les variables d'environnement depuis le fichier .env
    set -o allexport
    source "$ENV_FILE"
    set +o allexport
else
    echo "❌ Fichier $ENV_FILE introuvable !"
    echo "   Veuillez créer un fichier .env avec au minimum :"
    echo "   OS_HOST=<host>:<port>"
    echo "   AUTH=-u <user>:<password>"
    exit 1
fi

# ------------------------------------------------------------------------------
# Validation des variables obligatoires
# ------------------------------------------------------------------------------
if [ -z "$OS_HOST" ]; then
    echo "❌ Variable OS_HOST non définie dans $ENV_FILE"
    exit 1
fi

if [ -z "$AUTH" ]; then
    echo "❌ Variable AUTH non définie dans $ENV_FILE"
    exit 1
fi

# ------------------------------------------------------------------------------
# Configuration par defaut (peut être écrasée par les arguments)
# ------------------------------------------------------------------------------
FILTER_TEMP=""
FILTER_ZONE=""
FORCE_REFRESH=""
RESUME=""
LOG_DIR_OVERRIDE=""
CACHE_TTL=300         # secondes avant re-fetch (5 min)
# CURL_OPTS="-k"      # si TLS auto-signe

# Initialiser les compteurs pour eviter les erreurs
COUNT_ATTENTE=0
COUNT_STALE=0
COUNT_PERDU=0
COUNT_NOREP=0
PANNE_MODE=0
OFFLINE_ZONES=""
OFFLINE_NODES=""

# ------------------------------------------------------------------------------
# Nettoyage des fichiers temporaires en cas d'interruption
# ------------------------------------------------------------------------------
cleanup() {
    rm -f /tmp/shard_started.* /tmp/shard_init.* 2>/dev/null
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# Parsing des arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --temp)      FILTER_TEMP="$2";     shift 2 ;;
        --zone)      FILTER_ZONE="$2";     shift 2 ;;
        --no-cache)  FORCE_REFRESH=1;      shift   ;;
        --resume)    RESUME=1;             shift   ;;
        --log-dir)   LOG_DIR_OVERRIDE="$2"; shift 2 ;;
        *) OS_HOST="$1"; shift ;;
    esac
done

# ------------------------------------------------------------------------------
# Construction du nom de dossier avec les parametres du run
# Format : os_diag_YYYYMMDD_HHMMSS_HOST_temp-XX_zone-YY
# ------------------------------------------------------------------------------
RUN_DATE=$(date '+%Y%m%d_%H%M%S')
RUN_DATE_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')

# Nettoyer le host pour le nom de dossier (remplacer : par -)
HOST_SLUG=$(echo "$OS_HOST" | tr ':' '-')
DIR_SUFFIX="${HOST_SLUG}"
[ -n "$FILTER_TEMP" ] && DIR_SUFFIX="${DIR_SUFFIX}_temp-${FILTER_TEMP}"
[ -n "$FILTER_ZONE" ] && DIR_SUFFIX="${DIR_SUFFIX}_zone-${FILTER_ZONE}"

if [ -n "$LOG_DIR_OVERRIDE" ]; then
    LOG_DIR="$LOG_DIR_OVERRIDE"
elif [ -n "$RESUME" ]; then
    # En mode resume sans --log-dir : chercher le dernier run correspondant aux memes params
    LAST_RUN=$(ls -1dt /tmp/os_diag_*_${HOST_SLUG}* 2>/dev/null | head -1)
    LOG_DIR="${LAST_RUN:-/tmp/os_diag_${RUN_DATE}_${DIR_SUFFIX}}"
    echo "Resume detecte : utilisation du repertoire $LOG_DIR"
else
    LOG_DIR="/tmp/os_diag_${RUN_DATE}_${DIR_SUFFIX}"
fi

mkdir -p "$LOG_DIR"

# ------------------------------------------------------------------------------
# Fichiers de log par nature
# ------------------------------------------------------------------------------
LOG_MAIN="$LOG_DIR/diagnostic.log"             # log principal (tout)
LOG_NODES="$LOG_DIR/nodes.log"                 # tableau des noeuds decouverts
LOG_RISK="$LOG_DIR/risk_shards.log"            # shards en copie unique (DANGER)
LOG_REPLICATING="$LOG_DIR/replicating_shards.log" # shards INITIALIZING (replication en cours)
LOG_UNASSIGNED="$LOG_DIR/unassigned_shards.log"   # shards vraiment non assignes
LOG_UNRECOVERABLE="$LOG_DIR/unrecoverable_shards.log" # shards STALE ou PERDU (etape 5)
LOG_NOREP="$LOG_DIR/norep_shards.log"                 # shards sans replica par politique ISM
LOG_REMEDIATION="$LOG_DIR/remediation.log"            # commandes de remediation generees
LOG_SAFE="$LOG_DIR/safe_shards.log"            # shards avec replicas OK
LOG_NODE_STATS="$LOG_DIR/node_stats.log"       # repartition par noeud
LOG_INDEX_VOL="$LOG_DIR/index_volumes.log"     # volumetrie totale par index concerne
LOG_SUMMARY="$LOG_DIR/summary.log"             # resume executif
LOG_ERRORS="$LOG_DIR/errors.log"               # erreurs uniquement

# Fichiers CSV (synthese)
LOG_INDEX_SUMMARY_CSV="$LOG_DIR/index_summary.csv"
LOG_SHARD_SUMMARY_CSV="$LOG_DIR/shard_summary.csv"

# Fichiers internes (cache/checkpoint)
CACHE_DIR="$LOG_DIR/cache"
CHECKPOINT_FILE="$CACHE_DIR/checkpoint"
CACHE_NODES="$CACHE_DIR/nodes.json"
CACHE_SHARDS="$CACHE_DIR/shards.txt"
CACHE_NODES_PARSED="$CACHE_DIR/nodes_parsed.txt"
TARGET_NODES_FILE="$CACHE_DIR/target_nodes.txt"
RISK_FILE="$CACHE_DIR/risk_analysis.txt"
NODE_STATS_FILE="$CACHE_DIR/node_stats.txt"
INDEX_VOL_FILE="$CACHE_DIR/index_volumes.txt"
CACHE_INDICES="$CACHE_DIR/indices.txt"

mkdir -p "$CACHE_DIR"

# Construction de la base curl
CURL="curl -s --max-time 30 --retry 3 --retry-delay 2 ${AUTH} ${CURL_OPTS} https://${OS_HOST}/"

# ------------------------------------------------------------------------------
# Fonctions utilitaires
# ------------------------------------------------------------------------------

log() {
    local msg="[$(date '+%H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_MAIN"
}
log_ok()   { log "✅ $*"; }
log_warn() { log "⚠️  $*"; }
log_err()  {
    local msg="[$(date '+%H:%M:%S')] 🔴 $*"
    echo "$msg" >&2
    echo "$msg" >> "$LOG_MAIN"
    echo "$msg" >> "$LOG_ERRORS"
}

log_to() {
    local file="$1"; shift
    echo "$*" | tee -a "$file" >> "$LOG_MAIN"
}

checkpoint_set() { echo "$1" > "$CHECKPOINT_FILE"; log "Checkpoint : $1"; }
checkpoint_get() { [ -f "$CHECKPOINT_FILE" ] && cat "$CHECKPOINT_FILE" || echo "START"; }

cache_valid() {
    local file="$1"
    [ -z "$FORCE_REFRESH" ] || return 1
    [ -f "$file" ]          || return 1
    local now age
    now=$(date +%s)
    age=$(( now - $(date -r "$file" +%s 2>/dev/null || echo 0) ))
    [ "$age" -lt "$CACHE_TTL" ]
}

api_fetch() {
    local endpoint="$1"
    local cache_file="$2"
    local description="$3"

    if cache_valid "$cache_file"; then
        log "Cache valide pour $description ($(wc -c < "$cache_file") bytes)"
        return 0
    fi

    log "Fetch $description via /${endpoint} ..."
    local tmp="${cache_file}.tmp"
    local http_code

    http_code=$(${CURL}${endpoint} -w "%{http_code}" -o "$tmp")

    if [ "$http_code" != "200" ] || [ ! -s "$tmp" ]; then
        log_err "Echec fetch $description (HTTP $http_code)"
        rm -f "$tmp"
        if [ -f "$cache_file" ]; then
            log_warn "Utilisation du cache expire pour $description"
            return 0
        fi
        return 1
    fi

    mv "$tmp" "$cache_file"
    log_ok "$description fetche ($(wc -c < "$cache_file") bytes)"
}

section() {
    local file="$1"
    local title="$2"
    {
        echo ""
        echo "=================================================================="
        echo "  $title"
        echo "  $(date '+%Y-%m-%d %H:%M:%S')"
        echo "=================================================================="
    } | tee -a "$file" >> "$LOG_MAIN"
}

# ------------------------------------------------------------------------------
# En-tete
# ------------------------------------------------------------------------------
{
    echo "=================================================================="
    echo " Diagnostic shards a risque OpenSearch"
    echo " Date      : $RUN_DATE_HUMAN"
    echo " Host      : $OS_HOST"
    echo " Log dir   : $LOG_DIR"
    echo " Cache TTL : ${CACHE_TTL}s"
    [ -n "$FILTER_TEMP" ] && echo " Filtre temp : $FILTER_TEMP"
    [ -n "$FILTER_ZONE" ] && echo " Filtre zone : $FILTER_ZONE"
    echo "=================================================================="
    echo ""
    echo "Fichiers de log generes :"
    echo "  diagnostic.log        -> log complet de l'execution"
    echo "  nodes.log             -> noeuds decouverts et filtres"
    echo "  risk_shards.log       -> shards en COPIE UNIQUE (DANGER)"
    echo "  replicating_shards.log-> shards INITIALIZING (replication en cours)"
    echo "  unassigned_shards.log -> shards vraiment non assignes"
    echo "  unrecoverable_shards.log -> classification ATTENTE/STALE/PERDU"
    echo "  remediation.log       -> commandes curl pret-a-l-emploi"
    echo "  safe_shards.log       -> shards avec replicas OK"
    echo "  node_stats.log        -> repartition par noeud cible"
    echo "  index_volumes.log     -> volumetrie totale des index concernes"
    echo "  summary.log           -> resume executif"
    echo "  index_summary.csv     -> synthese par index (CSV)"
    echo "  shard_summary.csv     -> detail par shard (CSV)"
    echo "  errors.log            -> erreurs uniquement"
    echo ""
} | tee "$LOG_MAIN"

{
    echo "RESUME EXECUTIF - Diagnostic OpenSearch"
    echo "Date         : $RUN_DATE_HUMAN"
    echo "Host         : $OS_HOST"
    echo "Parametres   : host=${OS_HOST} temp=${FILTER_TEMP:-*} zone=${FILTER_ZONE:-*}"
    echo "Log dir      : $LOG_DIR"
    echo ""
} > "$LOG_SUMMARY"

# ------------------------------------------------------------------------------
# Reprise sur erreur
# ------------------------------------------------------------------------------
LAST_CHECKPOINT=$(checkpoint_get)
if [ -n "$RESUME" ] && [ "$LAST_CHECKPOINT" != "START" ]; then
    log "Reprise depuis checkpoint : $LAST_CHECKPOINT"
else
    checkpoint_set "START"
    LAST_CHECKPOINT="START"
fi

# ------------------------------------------------------------------------------
# ETAPE 1 — Decouverte des noeuds
# ------------------------------------------------------------------------------
if [ "$LAST_CHECKPOINT" = "START" ]; then

    section "$LOG_NODES" "ETAPE 1/5 - Decouverte des noeuds"
    checkpoint_set "NODES_RUNNING"

    api_fetch \
        "_nodes?filter_path=nodes.*.name,nodes.*.attributes" \
        "$CACHE_NODES" \
        "noeuds" || { log_err "Abandon etape 1 - impossible de contacter $OS_HOST"; exit 1; }

    # Utiliser le script awk externe pour parser les nodes
    awk -f "$(dirname "$0")/awk_scripts/parse_nodes.awk" "$CACHE_NODES" > "$CACHE_NODES_PARSED"

    if [ ! -s "$CACHE_NODES_PARSED" ]; then
        log_err "Aucun noeud parse. Verifiez node.attr.zone / node.attr.temp dans opensearch.yml"
        exit 1
    fi

    NODE_TOTAL=$(wc -l < "$CACHE_NODES_PARSED" | tr -d ' ')
    log_ok "$NODE_TOTAL noeud(s) decouverts"

    {
        printf "%-30s %-10s %s\n" "NOM" "TEMP" "ZONE"
        printf '%s\n' "----------------------------------------------------"
        awk -f "$(dirname "$0")/awk_scripts/format_nodes.awk" "$CACHE_NODES_PARSED"
        echo ""
        echo "Total : $NODE_TOTAL noeud(s)"
    } | tee -a "$LOG_NODES" >> "$LOG_MAIN"

    # --------------------------------------------------------------------------
    # DÉTECTION DES NŒUDS/ZONES HORS LIGNE
    # --------------------------------------------------------------------------
    # 1. Extraire toutes les zones et temp attendues
    ALL_ZONES=$(awk -f "$(dirname "$0")/awk_scripts/extract_zones_temps.awk" -v field=2 "$CACHE_NODES_PARSED" | sort -u | tr '\n' ' ')
    ALL_TEMPS=$(awk -f "$(dirname "$0")/awk_scripts/extract_zones_temps.awk" -v field=3 "$CACHE_NODES_PARSED" | sort -u | tr '\n' ' ')

    # 2. Compter le nombre de nœuds par zone/temp
    declare -A ZONE_COUNT
    declare -A TEMP_COUNT
    while IFS='|' read -r name zone temp; do
        ZONE_COUNT["$zone"]=$(( ${ZONE_COUNT["$zone"]:-0} + 1 ))
        TEMP_COUNT["$temp"]=$(( ${TEMP_COUNT["$temp"]:-0} + 1 ))
    done < "$CACHE_NODES_PARSED"

    # 3. Détecter les zones sans nœuds en ligne
    OFFLINE_ZONES=""
    for zone in $ALL_ZONES; do
        if [ -z "${ZONE_COUNT["$zone"]}" ] || [ "${ZONE_COUNT["$zone"]}" -eq 0 ]; then
            OFFLINE_ZONES="$OFFLINE_ZONES $zone"
        fi
    done
    OFFLINE_ZONES=$(echo "$OFFLINE_ZONES" | xargs)

    # 4. Détecter les nœuds manquants dans les zones partielles
    #    Supposons que toutes les zones ont le même nombre de nœuds (symétrie)
    MAX_ZONE_COUNT=0
    for zone in $ALL_ZONES; do
        [ "${ZONE_COUNT["$zone"]:-0}" -gt "$MAX_ZONE_COUNT" ] && MAX_ZONE_COUNT=${ZONE_COUNT["$zone"]}
    done

    for zone in $ALL_ZONES; do
        current_count=${ZONE_COUNT["$zone"]:-0}
        if [ "$current_count" -lt "$MAX_ZONE_COUNT" ] && [ "$current_count" -gt 0 ]; then
            missing=$(( MAX_ZONE_COUNT - current_count ))
            # Générer des noms de nœuds hypothétiques (ex: node-az1-01, node-az1-02, etc.)
            for ((i=1; i<=$missing; i++)); do
                OFFLINE_NODES="$OFFLINE_NODES node-${zone}-$(printf "%02d" $i)"
            done
        fi
    done
    OFFLINE_NODES=$(echo "$OFFLINE_NODES" | xargs | sed 's/ /,/g')

    # 5. Log des nœuds/zones hors ligne
    if [ -n "$OFFLINE_ZONES" ] || [ -n "$OFFLINE_NODES" ]; then
        log_warn "PANNE DÉTECTÉE : Zones hors ligne : $OFFLINE_ZONES | Nœuds hors ligne : $OFFLINE_NODES"
        PANNE_MODE=1
    else
        PANNE_MODE=0
    fi

    checkpoint_set "NODES_DONE"
    LAST_CHECKPOINT="NODES_DONE"
fi

# ------------------------------------------------------------------------------
# ETAPE 2 — Filtrage des noeuds cibles
# ------------------------------------------------------------------------------
if [ "$LAST_CHECKPOINT" = "NODES_DONE" ]; then

    section "$LOG_NODES" "ETAPE 2/5 - Filtrage des noeuds cibles"
    checkpoint_set "FILTER_RUNNING"

    # Utiliser le script awk externe pour filtrer les nodes
    awk -f "$(dirname "$0")/awk_scripts/filter_nodes.awk" \
        -v ft="$FILTER_TEMP" \
        -v fz="$FILTER_ZONE" \
        "$CACHE_NODES_PARSED" > "$TARGET_NODES_FILE"

    # Ajouter les nœuds hors ligne à la liste des cibles
    if [ -n "$OFFLINE_NODES" ]; then
        echo "$OFFLINE_NODES" | tr ',' '\n' >> "$TARGET_NODES_FILE"
        # Supprimer les doublons
        sort -u "$TARGET_NODES_FILE" -o "$TARGET_NODES_FILE"
        log "Nœuds hors ligne inclus dans l'analyse : $OFFLINE_NODES"
    fi

    if [ ! -s "$TARGET_NODES_FILE" ]; then
        log_err "Aucun noeud ne correspond aux filtres (temp=$FILTER_TEMP zone=$FILTER_ZONE)"
        log_err "Verifiez les valeurs de node.attr.temp et node.attr.zone"
        exit 1
    fi

    NODE_COUNT=$(wc -l < "$TARGET_NODES_FILE" | tr -d ' ')
    log_ok "$NODE_COUNT noeud(s) cible(s) apres filtrage"

    {
        echo "Noeuds cibles ($NODE_COUNT) :"
        sed 's/^/  - /' "$TARGET_NODES_FILE"
        echo ""
    } | tee -a "$LOG_NODES" >> "$LOG_MAIN"

    echo "Noeuds cibles : $NODE_COUNT" >> "$LOG_SUMMARY"

    checkpoint_set "FILTER_DONE"
    LAST_CHECKPOINT="FILTER_DONE"
fi

# ------------------------------------------------------------------------------
# ETAPE 3 — Recuperation des shards
# ------------------------------------------------------------------------------
if [ "$LAST_CHECKPOINT" = "FILTER_DONE" ]; then

    log "ETAPE 3/5 : Recuperation des shards et volumes du cluster"
    checkpoint_set "SHARDS_RUNNING"

    # Colonnes : index shard prirep state store node ip segments.count
    api_fetch \
        "_cat/shards?h=index,shard,prirep,state,store,node,ip,segments.count&bytes=b&s=index,shard" \
        "$CACHE_SHARDS" \
        "shards" || { log_err "Abandon etape 3 (shards)"; exit 1; }

    SHARD_TOTAL=$(wc -l < "$CACHE_SHARDS" | tr -d ' ')
    log_ok "$SHARD_TOTAL shards recuperes"
    echo "Total shards cluster : $SHARD_TOTAL" >> "$LOG_SUMMARY"

    # Volumetrie reelle des index via _cat/indices
    api_fetch \
        "_cat/indices?h=index,pri,rep,docs.count,store.size,pri.store.size&bytes=b&s=index" \
        "$CACHE_INDICES" \
        "indices (volumetrie)" || log_warn "Volumetrie indices non disponible - calcul depuis shards"

    # Construire rep_flat.txt pour exclure les replicas ISM (rep=0)
    CACHE_REP="$CACHE_DIR/rep_flat.txt"
    if [ -s "$CACHE_INDICES" ]; then
        awk -f "$(dirname "$0")/awk_scripts/build_rep_flat.awk" "$CACHE_INDICES" > "$CACHE_REP"
        log_ok "rep_flat construit ($(wc -l < "$CACHE_REP" | tr -d ' ') index) — ISM rep=0 sera exclu du RISK"
    else
        log_warn "CACHE_INDICES absent — shards ISM rep=0 non filtres a l etape 4"
        touch "$CACHE_REP"
    fi

    checkpoint_set "SHARDS_DONE"
    LAST_CHECKPOINT="SHARDS_DONE"
fi

# ------------------------------------------------------------------------------
# ETAPE 4 — Analyse (100% awk, zero fork en boucle)
# ------------------------------------------------------------------------------
if [ "$LAST_CHECKPOINT" = "SHARDS_DONE" ]; then

    log "ETAPE 4/5 : Analyse des risques (awk pur)"
    checkpoint_set "ANALYSIS_RUNNING"

    # Première passe : compter les copies STARTED et INITIALIZING par (index|shard)
    awk -v targets_file="$TARGET_NODES_FILE" '
        NR==FNR {targets[$1]=1; next}
        {
            key=$1"|"$2
            if ($4=="STARTED")      copies_started[key]++
            if ($4=="INITIALIZING") copies_init[key]++
        }
        END {
            for (k in copies_started) print k"|"copies_started[k] > "/tmp/shard_started.$$"
            for (k in copies_init)    print k"|"copies_init[k]    > "/tmp/shard_init.$$"
        }
    ' "$TARGET_NODES_FILE" "$CACHE_SHARDS"

    # Deuxième passe : classification des shards
    awk -v targets_file="$TARGET_NODES_FILE" \
        -v started_file="/tmp/shard_started.$$" \
        -v init_file="/tmp/shard_init.$$" \
        -v rep_file="$CACHE_DIR/rep_flat.txt" \
    '
        BEGIN {
            while ((getline line < targets_file) > 0) targets[line]=1
            while ((getline line < started_file) > 0) {
                split(line, a, "|"); started[a[1]"|"a[2]] = a[3]+0
            }
            while ((getline line < init_file) > 0) {
                split(line, a, "|"); init[a[1]"|"a[2]] = a[3]+0
            }
            while ((getline line < rep_file) > 0) {
                split(line, a, "|"); replicas[a[1]] = a[2]+0
            }
        }
        {
            key = $1"|"$2
            idx = $1; role = $3
            if (!(key in started)) started[key] = 0
            if (!(key in init))    init[key]    = 0
            has_target = ($6 in targets)

            if (has_target) {
                if ($4 == "STARTED") {
                    if (role == "r" && (idx in replicas) && replicas[idx] == 0) {
                        print "NO_REPLICA|" started[key] "|" init[key] "|" $0
                    } else {
                        tag = (started[key] == 1) ? "RISK" : "SAFE"
                        print tag "|" started[key] "|" init[key] "|" $0
                    }
                } else if ($4 == "INITIALIZING") {
                    print "REPLICATING|" started[key] "|" init[key] "|" $0
                } else {
                    if (role == "r" && (idx in replicas) && replicas[idx] == 0) {
                        print "NO_REPLICA|" started[key] "|" init[key] "|" $0
                    } else {
                        tag = (started[key] <= 1) ? "RISK" : "SAFE"
                        print tag "|" started[key] "|" init[key] "|" $0
                    }
                }
            } else {
                if ($4 == "INITIALIZING") {
                    print "REPLICATING|" started[key] "|" init[key] "|" $0
                } else if ($4 == "UNASSIGNED") {
                    print "UNASSIGNED|" started[key] "|" init[key] "|" $0
                }
            }
        }
    ' "$CACHE_SHARDS" > "$RISK_FILE"
    rm -f /tmp/shard_started.$ /tmp/shard_init.$

    # Stats par noeud cible
    awk -f "$(dirname "$0")/awk_scripts/node_stats.awk" -v tfile="$TARGET_NODES_FILE" "$CACHE_SHARDS" > "$NODE_STATS_FILE"

    # Volumetrie totale par index concerne
    awk -f "$(dirname "$0")/awk_scripts/concerned_indexes.awk" -v tfile="$TARGET_NODES_FILE" "$CACHE_SHARDS" > "$CACHE_DIR/concerned_indexes.txt"

    if [ -s "$CACHE_INDICES" ]; then
        awk -f "$(dirname "$0")/awk_scripts/filter_concerned_indices.awk" -v cfile="$CACHE_DIR/concerned_indexes.txt" "$CACHE_INDICES" > "$INDEX_VOL_FILE"
    else
        awk -f "$(dirname "$0")/awk_scripts/volumetrie_fallback.awk" -v tfile="$TARGET_NODES_FILE" "$CACHE_SHARDS" > "$INDEX_VOL_FILE"
    fi

    checkpoint_set "ANALYSIS_DONE"
    LAST_CHECKPOINT="ANALYSIS_DONE"
fi

# ------------------------------------------------------------------------------
# ETAPE 5 — Classification des shards UNASSIGNED
# ------------------------------------------------------------------------------
section "$LOG_UNRECOVERABLE" "ETAPE 5/5 - Classification des shards UNASSIGNED"

# Extraire les shards tagués UNASSIGNED depuis l'analyse etape 4
UNASSIGNED_FROM_ANALYSIS=$(grep "^UNASSIGNED|" "$RISK_FILE" 2>/dev/null || true)

if [ -z "$UNASSIGNED_FROM_ANALYSIS" ]; then
    echo "✅ Aucun shard UNASSIGNED a classifier." | tee -a "$LOG_UNRECOVERABLE" >> "$LOG_MAIN"
    COUNT_ATTENTE=0
    COUNT_STALE=0
    COUNT_PERDU=0
else
    TOTAL_TO_CLASSIFY=$(echo "$UNASSIGNED_FROM_ANALYSIS" | wc -l | tr -d ' ')
    log "Classification de $TOTAL_TO_CLASSIFY shard(s) UNASSIGNED via _cluster/state"

    {
        echo "Methode : GET /_cluster/state/metadata,routing_table par shard"
        echo "Categories :"
        echo "  ATTENTE_NOEUD : copie connue sur noeud absent -> recovery auto au retour"
        echo "  STALE         : copie perimee sur disque      -> allocate_stale_primary + accept_data_loss"
        echo "  PERDU         : aucune copie valide connue    -> allocate_empty_primary + accept_data_loss"
        echo ""
        printf "%-45s %-7s %-5s %-14s %-10s %s\n" \
               "INDEX" "SHARD" "ROLE" "CLASSIFICATION" "TAILLE" "DETAIL"
        printf '%s\n' "$(printf '%0.s-' {1..130})"
    } >> "$LOG_UNRECOVERABLE"

    # Initialiser le fichier de remediation
    {
        echo "# Commandes de remediation OpenSearch"
        echo "# Generees le $(date)"
        echo "# Host : $OS_HOST"
        echo "# ATTENTION : ces commandes impliquent accept_data_loss"
        echo "# Remplacer NOEUD_CIBLE par le nom du noeud de destination"
        echo ""
    } > "$LOG_REMEDIATION"

    COUNT_ATTENTE=0
    COUNT_STALE=0
    COUNT_PERDU=0
    COUNT_NOREP=0
    CACHE_STATE_DIR="$CACHE_DIR/cluster_state"
    mkdir -p "$CACHE_STATE_DIR"

    CACHE_STATE_ALL="$CACHE_STATE_DIR/all_indexes.json"
    CACHE_INSYNC="$CACHE_STATE_DIR/insync_flat.txt"
    CACHE_ROUTING="$CACHE_STATE_DIR/routing_flat.txt"
    CACHE_REP="$CACHE_DIR/rep_flat.txt"

    # Construire rep_flat.txt depuis le cache _cat/indices
    if [ ! -s "$CACHE_REP" ] && [ -s "$CACHE_INDICES" ]; then
        awk -f "$(dirname "$0")/awk_scripts/build_rep_flat.awk" "$CACHE_INDICES" > "$CACHE_REP"
        log "rep_flat.txt construit depuis cache indices ($(wc -l < "$CACHE_REP" | tr -d ' ') index)"
    elif [ ! -s "$CACHE_REP" ]; then
        log_warn "CACHE_INDICES absent — nombre de replicas non disponible (ISM non detecte)"
        touch "$CACHE_REP"
    fi

    # Liste CSV des index uniques ayant des shards UNASSIGNED
    # Extraire uniquement le premier mot du 4ème champ (au cas où il contient des espaces)
    INDEX_CSV=$(echo "$UNASSIGNED_FROM_ANALYSIS" \
        | awk -f "$(dirname "$0")/awk_scripts/extract_index_names.awk" | sort -u | tr '\n' ',' | sed 's/,$//')

    INDEX_COUNT=$(echo "$UNASSIGNED_FROM_ANALYSIS" \
        | awk -f "$(dirname "$0")/awk_scripts/extract_index_names.awk" | sort -u | wc -l | tr -d ' ')

    log "Fetch cluster state (metadata+routing_table) — $INDEX_COUNT index en un seul appel"

    if ! cache_valid "$CACHE_STATE_ALL"; then
        HTTP_CODE=$(${CURL}_cluster/state/metadata,routing_table/${INDEX_CSV}?pretty \
            -w "%{http_code}" -o "$CACHE_STATE_ALL" 2>/dev/null)
        if [ "$HTTP_CODE" != "200" ] || [ ! -s "$CACHE_STATE_ALL" ]; then
            log_warn "Fetch filtre echoue (HTTP $HTTP_CODE) — fallback sans filtre index"
            HTTP_CODE=$(${CURL}_cluster/state/metadata,routing_table?pretty \
                -w "%{http_code}" -o "$CACHE_STATE_ALL" 2>/dev/null)
        fi
        if [ "$HTTP_CODE" != "200" ] || [ ! -s "$CACHE_STATE_ALL" ]; then
            log_err "Fetch cluster state impossible — etape 5 ignoree"
            COUNT_ATTENTE=0
            COUNT_STALE=0
            COUNT_PERDU=0
        else
            log_ok "Cluster state fetche ($(wc -c < "$CACHE_STATE_ALL" | tr -d ' ') bytes)"
        fi
    else
        log "Cache cluster state valide"
    fi

    # Parsing cluster state (un seul awk POSIX)
    if [ -s "$CACHE_STATE_ALL" ] && \
       { ! cache_valid "$CACHE_INSYNC" || ! cache_valid "$CACHE_ROUTING"; }; then

        log "Parsing cluster state (un seul awk POSIX)..."

        # Utiliser le script awk externe pour parser le cluster state
        awk -f "$(dirname "$0")/awk_scripts/parse_cluster_state.awk" \
            insync_out="$CACHE_INSYNC" routing_out="$CACHE_ROUTING" "$CACHE_STATE_ALL"

        log_ok "Parsing termine — insync: $(wc -l < "$CACHE_INSYNC" | tr -d ' ') entrees, routing: $(wc -l < "$CACHE_ROUTING" | tr -d ' ') entrees"
    else
        log "Cache insync/routing valides — parsing ignore"
    fi

    # Classification des shards UNASSIGNED
    log "Classification des shards UNASSIGNED (awk pur — zero fork)..."
    
    # Fichier de données structuré pour les CSV (format : index|shard|role|status|size_gb|node|details)
    CLASSIFICATION_DATA="$CACHE_STATE_DIR/classification_data.txt"
    touch "$CLASSIFICATION_DATA"

    echo "$UNASSIGNED_FROM_ANALYSIS" | awk -F'|' \
        -v insync_file="$CACHE_INSYNC" \
        -v routing_file="$CACHE_ROUTING" \
        -v rep_file="$CACHE_REP" \
        -v os_host="$OS_HOST" \
        -v offline_nodes="$OFFLINE_NODES" \
        -v log_unrec="$LOG_UNRECOVERABLE" \
        -v log_norep="$LOG_NOREP" \
        -v log_remed="$LOG_REMEDIATION" \
        -v cnt_file="$CACHE_STATE_DIR/counts.txt" \
        -v class_data="$CLASSIFICATION_DATA" \
    '
        BEGIN {
            # Charger offline_nodes dans un tableau
            split(offline_nodes, nodes_list, ",")
            for (i in nodes_list) {
                offline[nodes_list[i]] = 1
            }

            # Charger insync en memoire : insync["index|shard"] = "id1,id2,..."
            while ((getline line < insync_file) > 0) {
                n = split(line, f, "|")
                if (n >= 3) insync[f[1] "|" f[2]] = f[3]
            }
            close(insync_file)

            # Charger routing en memoire : routing["index|shard"] = "alloc_id|node"
            while ((getline line < routing_file) > 0) {
                n = split(line, f, "|")
                if (n >= 3) {
                    routing[f[1] "|" f[2]] = f[3] "|" f[4]
                }
            }
            close(routing_file)

            # Charger nb replicas par index
            while ((getline line < rep_file) > 0) {
                n = split(line, f, "|")
                if (n >= 2) replicas[f[1]] = f[2] + 0
            }
            close(rep_file)

            cnt_attente = 0; cnt_stale = 0; cnt_perdu = 0; cnt_norep = 0
            fmt = "%-45s %-7s %-5s %-16s %-10s %s\n"
        }

        # Colonnes UNASSIGNED_FROM_ANALYSIS : tag|started|init|index|shard|role|state|store|node|ip
        $1 == "UNASSIGNED" {
            idx = $4; shard = $5; role = $6; store = $8
            key = idx "|" shard
            size_gb = sprintf("%.2f", (store + 0) / 1024 / 1024 / 1024)

            # --- Cas 0 : index sans replica par politique ISM ---
            if ((idx in replicas) && replicas[idx] == 0 && role == "r") {
                cnt_norep++
                detail = "ISM/politique : number_of_replicas=0 (voulu, pas un risque)"
                printf fmt, idx, shard, role, "NO_REPLICA", size_gb "GB", detail >> log_norep
                # Écrire dans class_data (format : index|shard|role|status|size_gb|node|details)
                printf "%s|%s|%s|NO_REPLICA|%.2f||%s\n", idx, shard, role, size_gb, detail >> class_data
                next
            }

            # Récupérer alloc_id et node depuis routing
            alloc_info = (key in routing) ? routing[key] : "NONE|NONE"
            split(alloc_info, a_info, "|")
            alloc_id = a_info[1]
            rt_node = a_info[2]

            # --- Cas 1 : aucun allocation_id connu ---
            if (alloc_id == "NONE" || alloc_id == "") {
                cnt_perdu++
                detail = "Aucun allocation_id dans routing_table"
                printf fmt, idx, shard, role, "PERDU", size_gb "GB", detail >> log_unrec
                printf "# INDEX: %s | SHARD: %s | TAILLE: %sGB | PERTE TOTALE\n", \
                    idx, shard, size_gb >> log_remed
                printf "curl -ku admin:admin -X POST \"http://%s/_cluster/reroute\" \\\n", \
                    os_host >> log_remed
                printf "  -H \"Content-Type: application/json\" \\\n" >> log_remed
                printf "  -d \x27{\"commands\":[{\"allocate_empty_primary\":{\"index\":\"%s\",\"shard\":%s,\"node\":\"NOEUD_CIBLE\",\"accept_data_loss\":true}}]}\x27\n\n", \
                    idx, shard >> log_remed
                # Écrire dans class_data
                printf "%s|%s|%s|PERDU|%.2f|%s|%s\n", idx, shard, role, size_gb, rt_node, detail >> class_data
                next
            }

            # --- Cas 2 : shard absent de in_sync_allocations ---
            insync_ids = (key in insync) ? insync[key] : ""
            if (insync_ids == "") {
                cnt_perdu++
                detail = "Shard absent de in_sync_allocations"
                printf fmt, idx, shard, role, "PERDU", size_gb "GB", detail >> log_unrec
                printf "# INDEX: %s | SHARD: %s | TAILLE: %sGB | PERTE TOTALE\n", \
                    idx, shard, size_gb >> log_remed
                printf "curl -ku admin:admin -X POST \"http://%s/_cluster/reroute\" \\\n", \
                    os_host >> log_remed
                printf "  -H \"Content-Type: application/json\" \\\n" >> log_remed
                printf "  -d \x27{\"commands\":[{\"allocate_empty_primary\":{\"index\":\"%s\",\"shard\":%s,\"node\":\"NOEUD_CIBLE\",\"accept_data_loss\":true}}]}\x27\n\n", \
                    idx, shard >> log_remed
                # Écrire dans class_data
                printf "%s|%s|%s|PERDU|%.2f|%s|%s\n", idx, shard, role, size_gb, rt_node, detail >> class_data
                next
            }

            # --- Cas 3 : croiser alloc_id avec la liste in_sync ---
            found = 0
            n = split(insync_ids, ids, ",")
            for (i = 1; i <= n; i++) {
                if (ids[i] == alloc_id) { found = 1; break }
            }

            # Vérifier si le nœud est hors ligne (priorité à ATTENTE_NOEUD)
            is_offline = (rt_node in offline) ? 1 : 0

            if (found) {
                if (is_offline) {
                    cnt_attente++
                    detail = "alloc_id in_sync — noeud hors ligne, recovery auto au retour"
                } else {
                    cnt_attente++
                    detail = "alloc_id in_sync — recovery auto au retour du noeud"
                }
                status = "ATTENTE_NOEUD"
                printf fmt, idx, shard, role, status, size_gb "GB", detail >> log_unrec
                # Écrire dans class_data
                printf "%s|%s|%s|%s|%.2f|%s|%s\n", idx, shard, role, status, size_gb, rt_node, detail >> class_data
            } else {
                if (is_offline) {
                    cnt_stale++
                    detail = "alloc_id hors in_sync — noeud hors ligne, copie perimee"
                } else {
                    cnt_stale++
                    detail = "alloc_id hors in_sync (id=" alloc_id ")"
                }
                status = "STALE"
                printf fmt, idx, shard, role, status, size_gb "GB", detail >> log_unrec
                printf "# INDEX: %s | SHARD: %s | TAILLE: %sGB | PERTE PARTIELLE POSSIBLE\n", \
                    idx, shard, size_gb >> log_remed
                printf "# allocation_id=%s hors in_sync=%s\n", alloc_id, insync_ids >> log_remed
                printf "curl -ku admin:admin -X POST \"http://%s/_cluster/reroute\" \\\n", \
                    os_host >> log_remed
                printf "  -H \"Content-Type: application/json\" \\\n" >> log_remed
                printf "  -d \x27{\"commands\":[{\"allocate_stale_primary\":{\"index\":\"%s\",\"shard\":%s,\"node\":\"NOEUD_CIBLE\",\"accept_data_loss\":true}}]}\x27\n\n", \
                    idx, shard >> log_remed
                # Écrire dans class_data
                printf "%s|%s|%s|%s|%.2f|%s|%s\n", idx, shard, role, status, size_gb, rt_node, detail >> class_data
            }
        }

        END {
            printf "%s|%s|%s|%s\n", cnt_attente, cnt_stale, cnt_perdu, cnt_norep > cnt_file
        }
    '

    # Recuperer les compteurs
    if [ -f "$CACHE_STATE_DIR/counts.txt" ]; then
        IFS='|' read -r COUNT_ATTENTE COUNT_STALE COUNT_PERDU COUNT_NOREP \
            < "$CACHE_STATE_DIR/counts.txt"
    else
        COUNT_ATTENTE=0
        COUNT_STALE=0
        COUNT_PERDU=0
        COUNT_NOREP=0
    fi

    log_ok "Classification terminee (ATTENTE=$COUNT_ATTENTE STALE=$COUNT_STALE PERDU=$COUNT_PERDU)"

    # Bilan etape 5
    {
        echo ""
        echo "--- Bilan de classification ---"
        printf "  ✅ ATTENTE_NOEUD : %-5s shard(s) — recovery auto au retour du noeud\n" "$COUNT_ATTENTE"
        printf "  ⚠️  STALE         : %-5s shard(s) — copie perimee, perte partielle possible\n" "$COUNT_STALE"
        printf "  🔴 PERDU          : %-5s shard(s) — aucune copie, perte totale\n" "$COUNT_PERDU"
        printf "  ℹ️  NO_REPLICA     : %-5s shard(s) — rep=0 par politique ISM (non bloquant)\n" "${COUNT_NOREP:-0}"
        echo ""
        NON_RECOV=$((COUNT_STALE + COUNT_PERDU))
        if [ "$NON_RECOV" -gt 0 ]; then
            echo "⛔ $NON_RECOV shard(s) NON recuperables automatiquement"
            echo "   Voir : $LOG_REMEDIATION"
        else
            echo "✅ Tous les shards UNASSIGNED problematiques seront recuperes automatiquement"
            echo "   (au retour du/des noeud(s) absent(s))"
        fi
        if [ "${COUNT_NOREP:-0}" -gt 0 ]; then
            echo ""
            echo "ℹ️  ${COUNT_NOREP} shard(s) ignores car number_of_replicas=0 (ISM/voulu)"
            echo "   Voir : $LOG_NOREP"
        fi
    } | tee -a "$LOG_UNRECOVERABLE" >> "$LOG_MAIN"

    log_ok "Etape 5 terminee (ATTENTE=$COUNT_ATTENTE STALE=$COUNT_STALE PERDU=$COUNT_PERDU)"
fi

# Compter les non recuperables pour le summary
NON_RECOV_TOTAL=$((COUNT_STALE + COUNT_PERDU))

# ------------------------------------------------------------------------------
# GENERATION DES FICHIERS CSV (SYNTHESE)
# ------------------------------------------------------------------------------

# 1. Generer index_summary.csv
log "Generation de index_summary.csv..."

# Vérifier que INDEX_VOL_FILE existe et n'est pas vide
if [ -s "$INDEX_VOL_FILE" ]; then
    {
        echo "index,total_shards,shards_at_risk,shards_replicating,shards_unassigned,shards_stale,shards_perdu,shards_norep,total_size_gb,status"
        awk -F'|' -v risk_file="$RISK_FILE" -v class_data="$CLASSIFICATION_DATA" '
            BEGIN {
                # Charger les compteurs par index depuis RISK_FILE
                while ((getline line < risk_file) > 0) {
                    split(line, f, "|")
                    tag = f[1]; idx = f[4]
                    if (tag == "RISK")        risk[idx]++
                    if (tag == "REPLICATING") replic[idx]++
                    if (tag == "UNASSIGNED")  unassign[idx]++
                    if (tag == "NO_REPLICA")  norep[idx]++
                }
                # Charger les classifications depuis classification_data.txt (format : index|shard|role|status|...)
                while ((getline line < class_data) > 0) {
                    split(line, f, "|")
                    if (NF >= 4) {
                        idx = f[1]; status = f[4]
                        if (status == "STALE") stale[idx]++
                        if (status == "PERDU") perdu[idx]++
                        if (status == "ATTENTE_NOEUD") attente[idx]++
                    }
                }
            }
            {
                idx = $1
                pri = $2 + 0; rep = $3 + 0
                total_shards = pri + rep
                risk_count = risk[idx] + 0
                replic_count = replic[idx] + 0
                unassign_count = unassign[idx] + 0
                stale_count = stale[idx] + 0
                perdu_count = perdu[idx] + 0
                norep_count = norep[idx] + 0
                size = $5 + 0
                size_gb = (size > 0) ? sprintf("%.2f", size/1024/1024/1024) : "0.00"

                # Déterminer le statut global de l index (priorité au plus critique)
                status = "OK"
                if (perdu_count > 0) status = "PERDU"
                else if (stale_count > 0) status = "STALE"
                else if (risk_count > 0) status = "RISK"
                else if (replic_count > 0) status = "REPLICATING"
                else if (unassign_count > 0) status = "UNASSIGNED"

                printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
                    idx, total_shards, risk_count, replic_count, unassign_count,
                    stale_count, perdu_count, norep_count, size_gb, status
            }
        ' "$INDEX_VOL_FILE"
    } > "$LOG_INDEX_SUMMARY_CSV"
    log_ok "index_summary.csv genere ($(wc -l < "$LOG_INDEX_SUMMARY_CSV" | tr -d ' ') index)"
else
    # Créer un CSV vide avec juste l'en-tête
    echo "index,total_shards,shards_at_risk,shards_replicating,shards_unassigned,shards_stale,shards_perdu,shards_norep,total_size_gb,status" > "$LOG_INDEX_SUMMARY_CSV"
    log_warn "index_summary.csv vide (INDEX_VOL_FILE non disponible)"
fi

# 2. Generer shard_summary.csv
log "Generation de shard_summary.csv..."

# Créer l'en-tête
{
    echo "index,shard,role,status,priority,state,copies_started,copies_init,node,ip,size_gb,details"

    # Shards RISK/SAFE/REPLICATING/NO_REPLICA de l etape 4
    if [ -s "$RISK_FILE" ]; then
        awk -F'|' '
            {
                tag = $1; idx = $4; shard = $5; role = $6; state = $7
                copies_started = $2 + 0; copies_init = $3 + 0
                node = $9; ip = $10
                size = $8 + 0  # Force la conversion en nombre (0 si vide)
                size_gb = (size > 0) ? sprintf("%.2f", size/1024/1024/1024) : "0.00"

                # Déterminer priority et details en fonction du tag
                if (tag == "RISK") {
                    priority = 1
                    details = "Copie unique - perte si " node " tombe"
                } else if (tag == "SAFE") {
                    priority = 4
                    details = copies_started " copies STARTED - safe"
                } else if (tag == "REPLICATING") {
                    priority = 3
                    details = "Réplication en cours - " copies_init " copies INITIALIZING"
                } else if (tag == "UNASSIGNED") {
                    priority = 2
                    details = "Non assigné - à classifier (étape 5)"
                } else if (tag == "NO_REPLICA") {
                    priority = 4
                    details = "ISM rep=0 - normal, non bloquant"
                } else {
                    priority = 4
                    details = "Statut inconnu"
                }

                printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,\"%s\"\n",
                    idx, shard, role, tag, priority, state, copies_started, copies_init,
                    node, ip, size_gb, details
            }
        ' "$RISK_FILE"
    fi

    # Shards classifiés en etape 5 (ATTENTE_NOEUD, STALE, PERDU)
    if [ -s "$LOG_UNRECOVERABLE" ]; then
        # Sauter les 5 premières lignes (en-tête) et traiter le reste
        tail -n +6 "$LOG_UNRECOVERABLE" | awk '
            NF >= 6 {
                idx = $1; shard = $2; role = $3; status = $4
                # Extraire la taille (colonne 5, format "X.XXGB" ou "X.XX")
                size_gb = $5
                gsub(/GB/, "", size_gb)
                # Vérifier que size_gb est un nombre valide
                if (size_gb !~ /^[0-9.]+$/) size_gb = "0.00"
                # Le reste de la ligne est "details" (colonnes 6+)
                details = ""
                for (i=6; i<=NF; i++) {
                    if (i > 6) details = details " "
                    details = details $i
                }
                gsub(/"/, "", details)
                # Déterminer priority
                if (status == "PERDU") priority = 1
                else if (status == "STALE") priority = 2
                else if (status == "ATTENTE_NOEUD") priority = 3
                else priority = 4
                printf "%s,%s,%s,%s,%s,UNASSIGNED,0,0,,,%s,\"%s\"\n",
                    idx, shard, role, status, priority, size_gb, details
            }
        '
    fi
} > "$LOG_SHARD_SUMMARY_CSV"

# Vérifier que le CSV n'est pas vide (juste l'en-tête)
SHARD_CSV_LINES=$(wc -l < "$LOG_SHARD_SUMMARY_CSV" | tr -d ' ')
if [ "$SHARD_CSV_LINES" -eq 1 ]; then
    log_warn "shard_summary.csv vide (aucune donnée disponible dans RISK_FILE ou LOG_UNRECOVERABLE)"
else
    log_ok "shard_summary.csv genere ($((SHARD_CSV_LINES - 1)) shards)"
fi

# ------------------------------------------------------------------------------
# COMPTAGES PAR CATEGORIE (pour la synthese)
# ------------------------------------------------------------------------------
RISK_COUNT=$(grep -c "^RISK|" "$RISK_FILE" 2>/dev/null || echo 0)
SAFE_COUNT=$(grep -c "^SAFE|" "$RISK_FILE" 2>/dev/null || echo 0)
REPLIC_COUNT=$(grep -c "^REPLICATING|" "$RISK_FILE" 2>/dev/null || echo 0)
UNASSIGNED_COUNT=$(grep -c "^UNASSIGNED|" "$RISK_FILE" 2>/dev/null || echo 0)
NOREP4_COUNT=$(grep -c "^NO_REPLICA|" "$RISK_FILE" 2>/dev/null || echo 0)


# ------------------------------------------------------------------------------
# SYNTHESE CONSOLE FINALE (Adaptée pour les pannes)
# ------------------------------------------------------------------------------
echo ""
echo "=================================================================="
if [ "$PANNE_MODE" -eq 1 ]; then
    log_ok "Diagnostic termine (MODE PANNE : nœuds/zones hors ligne détectés)"
else
    log_ok "Diagnostic termine"
fi
echo "=================================================================="
echo ""
echo " 📁 Logs : $LOG_DIR"
echo ""

# --- Section PANNE (si nœuds/zones hors ligne) ---
if [ "$PANNE_MODE" -eq 1 ]; then
    echo " 🚨 PANNE DÉTECTÉE"
    [ -n "$OFFLINE_ZONES" ] && echo "   Zones hors ligne : $OFFLINE_ZONES"
    [ -n "$OFFLINE_NODES" ] && echo "   Nœuds hors ligne : $OFFLINE_NODES"
    echo ""
fi

# --- Section PERTE DE DONNÉES (si COUNT_PERDU > 0) ---
if [ "${COUNT_PERDU:-0}" -gt 0 ]; then
    echo " 🔴 PERTE DE DONNÉES DÉTECTÉE"
    echo "   $COUNT_PERDU shard(s) PERDU → Aucune copie valide connue"
    PERDU_VOLUME=$(awk -f "$(dirname "$0")/awk_scripts/calc_volume.awk" -v status="PERDU" "$LOG_UNRECOVERABLE" 2>/dev/null || echo "?")
    echo "   Volume perdu : $PERDU_VOLUME"
    echo "   Index concernés :"
    grep "|PERDU" "$LOG_UNRECOVERABLE" | awk '{print "     - " $1}' | sort -u
    echo "   Actions :"
    echo "     1. Vérifier les snapshots : GET /_snapshot/_all"
    echo "     2. Exécuter les commandes dans remediation.log (accept_data_loss=true)"
    echo "     3. Si pas de snapshot, les données sont PERDUES"
    echo ""
fi

# --- Section RÉCUPÉRATION NÉCESSAIRE (STALE) ---
if [ "${COUNT_STALE:-0}" -gt 0 ]; then
    echo " ⚠️  RÉCUPÉRATION NÉCESSAIRE (STALE)"
    echo "   $COUNT_STALE shard(s) STALE → Copie périmée sur disque"
    STALE_VOLUME=$(awk -f "$(dirname "$0")/awk_scripts/calc_volume.awk" -v status="STALE" "$LOG_UNRECOVERABLE" 2>/dev/null || echo "?")
    echo "   Volume concerné : $STALE_VOLUME"
    echo "   Actions :"
    echo "     - Exécuter les commandes dans remediation.log (allocate_stale_primary)"
    echo ""
fi

# --- Section RÉCUPÉRATION AUTOMATIQUE (ATTENTE_NOEUD) ---
if [ "${COUNT_ATTENTE:-0}" -gt 0 ]; then
    echo " ℹ️  RÉCUPÉRATION AUTOMATIQUE (ATTENTE_NOEUD)"
    echo "   $COUNT_ATTENTE shard(s) ATTENTE_NOEUD → Recovery auto au retour des nœuds"
    ATTENTE_VOLUME=$(awk -f "$(dirname "$0")/awk_scripts/calc_volume.awk" -v status="ATTENTE" "$LOG_UNRECOVERABLE" 2>/dev/null || echo "?")
    echo "   Volume concerné : $ATTENTE_VOLUME"
    echo "   Actions :"
    echo "     - Redémarrer les nœuds hors ligne pour recovery automatique"
    echo ""
fi

# --- Section SHARDS À RISQUE (RISK) ---
if [ "$RISK_COUNT" -gt 0 ]; then
    echo " 🔴 SHARDS EN COPIE UNIQUE (RISK)"
    echo "   $RISK_COUNT shard(s) en copie unique → Perte de données si nœud tombe"
    echo "   Index concernés :"
    grep "^RISK|" "$RISK_FILE" | awk -F'|' '{print "     - " $4}' | sort -u
    echo "   Actions :"
    echo "     - Augmenter number_of_replicas sur les index concernés"
    echo "     - Attendre la réplication : GET /_cluster/health?wait_for_status=green"
    echo ""
fi

# --- Section SHARDS EN RÉPLICATION (REPLICATING) ---
if [ "$REPLIC_COUNT" -gt 0 ]; then
    echo " ⚠️  SHARDS EN RÉPLICATION (INITIALIZING)"
    echo "   $REPLIC_COUNT shard(s) en cours de réplication → Pas encore protégés"
    echo "   Actions :"
    echo "     - Attendre la fin de la réplication"
    echo ""
fi

# --- Synthèse Globale ---
echo " ✅ SYNTHÈSE GLOBALE"
echo "   - Total shards analysés : $SHARD_TOTAL"
TOTAL_VOL=$(awk -f "$(dirname "$0")/awk_scripts/total_volume.awk" "$CACHE_SHARDS" 2>/dev/null || echo "?")
echo "   - Volume total concerné : $TOTAL_VOL"
echo "   - Nœuds en ligne : $NODE_TOTAL"
[ -n "$OFFLINE_NODES" ] && echo "   - Nœuds hors ligne : $OFFLINE_NODES"
[ -n "$OFFLINE_ZONES" ] && echo "   - Zones hors ligne : $OFFLINE_ZONES"
echo ""

# --- Décision de Maintenance ---
if [ "${COUNT_PERDU:-0}" -gt 0 ]; then
    echo " ❌ MAINTENANCE IMPOSSIBLE : Perte de données détectée (shards PERDU)"
elif [ "$RISK_COUNT" -gt 0 ]; then
    echo " ❌ MAINTENANCE BLOQUÉE : $RISK_COUNT shard(s) en copie unique (RISK)"
elif [ "$REPLIC_COUNT" -gt 0 ]; then
    echo " ⚠️  MAINTENANCE À REPORTER : $REPLIC_COUNT shard(s) en réplication"
elif [ "${COUNT_STALE:-0}" -gt 0 ]; then
    echo " ⚠️  MAINTENANCE À REPORTER : $COUNT_STALE shard(s) STALE à récupérer"
elif [ "$PANNE_MODE" -eq 1 ]; then
    echo " ⚠️  MAINTENANCE DÉCONSEILLÉE : Panne en cours (nœuds/zones hors ligne)"
else
    echo " ✅ MAINTENANCE POSSIBLE : Aucun shard à risque"
fi

echo ""
echo " 📊 FICHIERS GÉNÉRÉS"
echo "   - $LOG_DIR/summary.log          → Résumé exécutif"
echo "   - $LOG_DIR/risk_shards.log       → Shards en copie unique (DANGER)"
echo "   - $LOG_DIR/remediation.log       → Commandes de récupération"
echo "   - $LOG_DIR/unrecoverable_shards.log → Classification (ATTENTE/STALE/PERDU)"
echo "   - $LOG_DIR/index_summary.csv     → Synthèse par index (CSV)"
echo "   - $LOG_DIR/shard_summary.csv     → Détail par shard (CSV)"
echo ""

# --- Actions Recommandées ---
echo " 💡 ACTIONS RECOMMANDÉES"
if [ "${COUNT_PERDU:-0}" -gt 0 ]; then
    echo "   1. Vérifier les snapshots : GET /_snapshot/_all"
    echo "   2. Exécuter remediation.log pour les shards PERDU (accept_data_loss=true)"
fi
if [ "${COUNT_STALE:-0}" -gt 0 ]; then
    echo "   3. Exécuter remediation.log pour les shards STALE (allocate_stale_primary)"
fi
if [ "$PANNE_MODE" -eq 1 ]; then
    echo "   4. Redémarrer les nœuds hors ligne : $OFFLINE_NODES"
fi
if [ "$RISK_COUNT" -gt 0 ]; then
    echo "   5. Augmenter les replicas : PUT /<index>/_settings -d '{"index.number_of_replicas": 1}'"
fi
echo "   6. Relancer le diagnostic : $0 $OS_HOST --no-cache $([ -n "$FILTER_TEMP" ] && echo "--temp $FILTER_TEMP") $([ -n "$FILTER_ZONE" ] && echo "--zone $FILTER_ZONE")"
echo ""
echo "=================================================================="

checkpoint_set "DONE"
