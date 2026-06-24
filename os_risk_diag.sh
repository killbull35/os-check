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
# Configuration par defaut
# ------------------------------------------------------------------------------
OS_HOST="localhost:9200"
FILTER_TEMP=""
FILTER_ZONE=""
FORCE_REFRESH=""
RESUME=""
LOG_DIR_OVERRIDE=""
CACHE_TTL=300         # secondes avant re-fetch (5 min)
# AUTH="-u admin:motdepasse"
# CURL_OPTS="-k"      # si TLS auto-signe

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

# Valeur par défaut du parallélisme si non fournie

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
LOG_REMEDIATION="$LOG_DIR/remediation.log"         # commandes de remediation generees
LOG_SAFE="$LOG_DIR/safe_shards.log"            # shards avec replicas OK
LOG_NODE_STATS="$LOG_DIR/node_stats.log"       # repartition par noeud
LOG_INDEX_VOL="$LOG_DIR/index_volumes.log"     # volumetrie totale par index concerne
LOG_SUMMARY="$LOG_DIR/summary.log"             # resume executif
LOG_ERRORS="$LOG_DIR/errors.log"               # erreurs uniquement

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
# Usage : ${CURL}_endpoint (sans slash intermediaire, l endpoint commence par _)
# Ex : ${CURL}_cat/shards?v  →  curl ... http://host:9200/_cat/shards?v
CURL="curl -s --max-time 30 --retry 3 --retry-delay 2 ${AUTH} ${CURL_OPTS} http://${OS_HOST}/"

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

    # CURL se termine par / et endpoint commence par _ : pas de double slash
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

    section "$LOG_NODES" "ETAPE 1/4 - Decouverte des noeuds"
    checkpoint_set "NODES_RUNNING"

    api_fetch \
        "_nodes?filter_path=nodes.*.name,nodes.*.attributes" \
        "$CACHE_NODES" \
        "noeuds" || { log_err "Abandon etape 1 - impossible de contacter $OS_HOST"; exit 1; }

    awk '
        BEGIN { RS=","; FS="\"" }
        /"name"/ && !/attr/ {
            if (name != "") print name "|" zone "|" temp
            for(i=1;i<=NF;i++) if($i=="name") { name=$(i+2); break }
            zone="-"; temp="-"
        }
        /"zone"/ { for(i=1;i<=NF;i++) if($i=="zone") { zone=$(i+2); break } }
        /"temp"/ { for(i=1;i<=NF;i++) if($i=="temp") { temp=$(i+2); break } }
        END      { if (name != "") print name "|" zone "|" temp }
    ' "$CACHE_NODES" > "$CACHE_NODES_PARSED"

    if [ ! -s "$CACHE_NODES_PARSED" ]; then
        log_err "Aucun noeud parse. Verifiez node.attr.zone / node.attr.temp dans opensearch.yml"
        exit 1
    fi

    NODE_TOTAL=$(wc -l < "$CACHE_NODES_PARSED" | tr -d ' ')
    log_ok "$NODE_TOTAL noeud(s) decouverts"

    {
        printf "%-30s %-10s %s\n" "NOM" "TEMP" "ZONE"
        printf '%s\n' "----------------------------------------------------"
        awk -F'|' '{printf "%-30s %-10s %s\n", $1, $3, $2}' "$CACHE_NODES_PARSED"
        echo ""
        echo "Total : $NODE_TOTAL noeud(s)"
    } | tee -a "$LOG_NODES" >> "$LOG_MAIN"

    checkpoint_set "NODES_DONE"
    LAST_CHECKPOINT="NODES_DONE"
fi

# ------------------------------------------------------------------------------
# ETAPE 2 — Filtrage des noeuds cibles
# ------------------------------------------------------------------------------
if [ "$LAST_CHECKPOINT" = "NODES_DONE" ]; then

    section "$LOG_NODES" "ETAPE 2/4 - Filtrage des noeuds cibles"
    checkpoint_set "FILTER_RUNNING"

    awk -F'|' \
        -v ft="$FILTER_TEMP" \
        -v fz="$FILTER_ZONE" '
        {
            name=$1; zone=$2; temp=$3
            if (ft != "" && temp != ft) next
            if (fz != "" && zone != fz) next
            print name
        }
    ' "$CACHE_NODES_PARSED" > "$TARGET_NODES_FILE"

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

    log "ETAPE 3/4 : Recuperation des shards et volumes du cluster"
    checkpoint_set "SHARDS_RUNNING"

    # Colonnes : index shard prirep state store node ip segments.count
    # state peut valoir : STARTED INITIALIZING RELOCATING UNASSIGNED
    api_fetch \
        "_cat/shards?h=index,shard,prirep,state,store,node,ip,segments.count&bytes=b&s=index,shard" \
        "$CACHE_SHARDS" \
        "shards" || { log_err "Abandon etape 3 (shards)"; exit 1; }

    SHARD_TOTAL=$(wc -l < "$CACHE_SHARDS" | tr -d ' ')
    log_ok "$SHARD_TOTAL shards recuperes"
    echo "Total shards cluster : $SHARD_TOTAL" >> "$LOG_SUMMARY"

    # Volumetrie reelle des index via _cat/indices
    # Colonnes : health status index uuid pri rep docs.count docs.deleted store.size pri.store.size
    api_fetch \
        "_cat/indices?h=index,pri,rep,docs.count,store.size,pri.store.size&bytes=b&s=index" \
        "$CACHE_INDICES" \
        "indices (volumetrie)" || log_warn "Volumetrie indices non disponible - calcul depuis shards"

    checkpoint_set "SHARDS_DONE"
    LAST_CHECKPOINT="SHARDS_DONE"
fi

# ------------------------------------------------------------------------------
# ETAPE 4 — Analyse (100% awk, zero fork en boucle)
# ------------------------------------------------------------------------------
if [ "$LAST_CHECKPOINT" = "SHARDS_DONE" ]; then

    log "ETAPE 4/4 : Analyse des risques (awk pur)"
    checkpoint_set "ANALYSIS_RUNNING"

    # -------------------------------------------------------------------------
    # Analyse principale des shards
    #
    # Tags de sortie :
    #   RISK        shard STARTED sur noeud cible, copie unique → perte si arret
    #   SAFE        shard STARTED sur noeud cible, replique ailleurs → OK
    #   REPLICATING shard INITIALIZING sur noeud cible ou replica d un shard
    #               cible qui se replique → replication en cours, pas encore sure
    #   UNASSIGNED  shard non assigne dans le cluster (ni STARTED ni INITIALIZING)
    #               dont le primaire est sur un noeud cible
    #
    # Colonnes du fichier de sortie :
    #   TAG | COPIES_STARTED | COPIES_INITIALIZING | index | shard | prirep |
    #   state | store | node | ip | segments
    # -------------------------------------------------------------------------
    # ---------------------------------------------------------------------
    # Première passe : compter les copies STARTED et INITIALIZING par (index|shard)
    # ---------------------------------------------------------------------
    awk -v targets_file="$TARGET_NODES_FILE" '
        NR==FNR {targets[$1]=1; next}
        {
            key=$1"|"$2
            if ($4=="STARTED")      copies_started[key]++
            if ($4=="INITIALIZING") copies_init[key]++
        }
        END {
            for (k in copies_started) print k"|"copies_started[k] > "/tmp/shard_started.$"
            for (k in copies_init)    print k"|"copies_init[k]    > "/tmp/shard_init.$"
        }
    ' "$TARGET_NODES_FILE" "$CACHE_SHARDS"

    # ---------------------------------------------------------------------
    # Deuxième passe : appliquer la logique de classification en utilisant les comptes calculés
    # ---------------------------------------------------------------------
    awk -v targets_file="$TARGET_NODES_FILE" -v started_file="/tmp/shard_started.$" -v init_file="/tmp/shard_init.$" '
        BEGIN {
            while ((getline line < targets_file) > 0) targets[line]=1
            while ((getline line < started_file) > 0) { split(line, a, "|"); started[a[1]"|"a[2]]=a[2] }
            while ((getline line < init_file) > 0)    { split(line, a, "|"); init[a[1]"|"a[2]]=a[2] }
        }
        {
            key=$1"|"$2
            # assure existence de compteurs
            if (!(key in started)) started[key]=0
            if (!(key in init))    init[key]=0
            # déterminer si le shard a une copie sur un noeud cible
            has_target=($6 in targets)
            if (has_target) {
                if ($4=="STARTED") {
                    tag = (started[key]==1) ? "RISK" : "SAFE"
                    print tag "|" started[key] "|" init[key] "|" $0
                } else if ($4=="INITIALIZING") {
                    print "REPLICATING|" started[key] "|" init[key] "|" $0
                } else {
                    tag = (started[key]<=1) ? "RISK" : "SAFE"
                    print tag "|" started[key] "|" init[key] "|" $0
                }
            } else {
                if ($4=="INITIALIZING") {
                    print "REPLICATING|" started[key] "|" init[key] "|" $0
                } else if ($4=="UNASSIGNED") {
                    print "UNASSIGNED|" started[key] "|" init[key] "|" $0
                }
                # STARTED hors cible ignoré
            }
        }
    ' "$CACHE_SHARDS" > "$RISK_FILE"
    # Nettoyage des fichiers temporaires de comptage
    rm -f /tmp/shard_started.$ /tmp/shard_init.$

    # --- Stats par noeud cible ---
    awk '
        BEGIN {
            while ((getline node < tfile) > 0) targets[node]=1
        }
        $4=="STARTED" && ($6 in targets) {
            count[$6]++
            size[$6] += $5
        }
        $4=="INITIALIZING" && ($6 in targets) {
            init_count[$6]++
        }
        $4!="STARTED" && $4!="INITIALIZING" && ($6 in targets) {
            other[$6]++
        }
        END {
            for (n in count)
                printf "%s|%s|%.2f|%s|%s\n",
                    n, count[n], size[n]/1024/1024/1024,
                    (init_count[n]+0), (other[n]+0)
        }
    ' tfile="$TARGET_NODES_FILE" "$CACHE_SHARDS" > "$NODE_STATS_FILE"

    # --- Volumetrie totale par index concerne ---
    # Identifier les index qui ont au moins un shard sur les noeuds cibles
    awk '
        BEGIN {
            while ((getline node < tfile) > 0) targets[node]=1
        }
        $4=="STARTED" && ($6 in targets) { concerned[$1] = 1 }
        END { for (idx in concerned) print idx }
    ' tfile="$TARGET_NODES_FILE" "$CACHE_SHARDS" > "$CACHE_DIR/concerned_indexes.txt"

    # Croiser avec _cat/indices pour la volumetrie reelle
    # Format cache_indices : index pri rep docs.count store.size pri.store.size
    if [ -s "$CACHE_INDICES" ]; then
        awk '
            BEGIN {
                while ((getline idx < cfile) > 0) concerned[idx] = 1
            }
            ($1 in concerned) {
                # Colonnes : index pri rep docs store_total pri_store
                printf "%s|%s|%s|%s|%s|%s\n", $1, $2, $3, $4, $5, $6
            }
        ' cfile="$CACHE_DIR/concerned_indexes.txt" "$CACHE_INDICES" > "$INDEX_VOL_FILE"
    else
        # Fallback : calcul depuis les shards si _cat/indices n est pas dispo
        awk '
            BEGIN {
                while ((getline node < tfile) > 0) targets[node]=1
            }
            $4=="STARTED" && ($6 in targets) { concerned[$1] = 1 }
            $4=="STARTED" && ($1 in concerned) {
                total_size[$1] += $5
                total_shards[$1]++
                if ($3 == "p") pri_size[$1] += $5
            }
            END {
                for (idx in concerned)
                    printf "%s|-|-|-|%.0f|%.0f\n",
                        idx, total_size[idx], pri_size[idx]
            }
        ' tfile="$TARGET_NODES_FILE" "$CACHE_SHARDS" > "$INDEX_VOL_FILE"
    fi

    checkpoint_set "ANALYSIS_DONE"
    LAST_CHECKPOINT="ANALYSIS_DONE"
fi

# ------------------------------------------------------------------------------
# COMPTAGES PAR CATEGORIE
# ------------------------------------------------------------------------------
# Comptage des catégories en une passe unique
awk '
    BEGIN {risk=safe=replic=unassigned=0}
    {
        if ($1=="RISK")       risk++
        else if ($1=="SAFE")  safe++
        else if ($1=="REPLICATING") replic++
        else if ($1=="UNASSIGNED")  unassigned++
    }
    END {
        print risk > "/tmp/risk_cnt"
        print safe > "/tmp/safe_cnt"
        print replic > "/tmp/replic_cnt"
        print unassigned > "/tmp/unassigned_cnt"
    }
' "$RISK_FILE"
RISK_COUNT=$(cat /tmp/risk_cnt)
SAFE_COUNT=$(cat /tmp/safe_cnt)
REPLIC_COUNT=$(cat /tmp/replic_cnt)
UNASSIGNED_COUNT=$(cat /tmp/unassigned_cnt)

# Entete commun des tableaux de shards
SHARD_HEADER='%-45s %-7s %-5s %-13s %-8s %-8s %-25s %-16s %s'
SHARD_COLS='"INDEX" "SHARD" "ROLE" "ETAT" "STARTED" "INIT" "NOEUD" "IP" "TAILLE"'
SEP_LINE=$(printf '%0.s-' {1..145})

print_shard_table() {
    # $1 = tag a filtrer, $2 = fichier de sortie
    local tag="$1" out="$2"
    eval printf "\"$SHARD_HEADER\"\n" $SHARD_COLS >> "$out"
    echo "$SEP_LINE" >> "$out"
    grep "^${tag}|" "$RISK_FILE" | awk -F'|' -v OFS='' '{
        size_gb = ($8 == "" || $8 == 0) ? "n/a" : sprintf("%.2f GB", $8/1024/1024/1024)
        printf "%-45s %-7s %-5s %-13s %-8s %-8s %-25s %-16s %s\n",
            $4, $5, $6, $7, $2, $3, $9, $10, size_gb
    }' >> "$out"
    echo "" >> "$out"
}

# ------------------------------------------------------------------------------
# LOG : shards a risque
# ------------------------------------------------------------------------------
section "$LOG_RISK" "SHARDS A RISQUE - Copie unique STARTED (perte de donnees possible)"
{
    echo "Legende :"
    echo "  ETAT    : etat actuel du shard sur ce noeud"
    echo "  STARTED : nb de copies STARTED dans tout le cluster"
    echo "  INIT    : nb de copies INITIALIZING (en cours de replication)"
    echo "  Si STARTED=1 et INIT>0 : la replication est en cours mais pas encore finalisee"
    echo ""
} >> "$LOG_RISK"

if [ "$RISK_COUNT" -eq 0 ]; then
    echo "✅ Aucun shard a risque detecte." | tee -a "$LOG_RISK" >> "$LOG_MAIN"
else
    printf "🔴 %s shard(s) en COPIE UNIQUE\n\n" "$RISK_COUNT" | tee -a "$LOG_RISK" >> "$LOG_MAIN"
    print_shard_table "RISK" "$LOG_RISK"

    # Recap par index
    {
        echo "--- Recapitulatif par index ---"
        printf "%-45s %-18s %-15s %s\n" "INDEX" "SHARDS A RISQUE" "TAILLE EXPOSEE" "REPLICATION EN COURS"
        printf '%s\n' "$(printf '%0.s-' {1..95})"
        grep "^RISK|" "$RISK_FILE" | awk -F'|' '{
            count[$4]++
            size[$4] += $8
            if ($3+0 > 0) replic[$4]++
        }
        END {
            for (i in count)
                printf "%-45s %-18s %-15s %s\n",
                    i, count[i],
                    sprintf("%.2f GB", size[i]/1024/1024/1024),
                    (replic[i]+0 > 0) ? "⚠️  oui (" replic[i] " shards)" : "non"
        }' | sort -k2 -rn
    } >> "$LOG_RISK"
fi
cat "$LOG_RISK" >> "$LOG_MAIN"

# ------------------------------------------------------------------------------
# LOG : shards en cours de replication (INITIALIZING)
# ------------------------------------------------------------------------------
section "$LOG_REPLICATING" "SHARDS EN COURS DE REPLICATION (INITIALIZING)"
{
    echo "Ces shards ne sont PAS encore proteges : la copie est en transit."
    echo "  - Si STARTED=1 : le primaire est seul, le replica n est pas encore utilisable"
    echo "  - Si STARTED=0 : le shard est en cours d affectation initiale"
    echo "  Attendre la fin de la replication avant toute maintenance."
    echo ""
} >> "$LOG_REPLICATING"

if [ "$REPLIC_COUNT" -eq 0 ]; then
    echo "✅ Aucun shard en cours de replication." >> "$LOG_REPLICATING"
else
    printf "⚠️  %s shard(s) INITIALIZING\n\n" "$REPLIC_COUNT" >> "$LOG_REPLICATING"
    print_shard_table "REPLICATING" "$LOG_REPLICATING"

    # Recap par index
    {
        echo "--- Recapitulatif par index ---"
        printf "%-45s %-20s %-12s %s\n" "INDEX" "SHARDS INITIALIZING" "STARTED" "TAILLE EN TRANSIT"
        printf '%s\n' "$(printf '%0.s-' {1..90})"
        grep "^REPLICATING|" "$RISK_FILE" | awk -F'|' '{
            count[$4]++
            started[$4] = $2
            size[$4]  += $8
        }
        END {
            for (i in count)
                printf "%-45s %-20s %-12s %.2f GB\n",
                    i, count[i], started[i], size[i]/1024/1024/1024
        }' | sort -k2 -rn
    } >> "$LOG_REPLICATING"
fi
cat "$LOG_REPLICATING" >> "$LOG_MAIN"

# ------------------------------------------------------------------------------
# LOG : shards vraiment non assignes
# ------------------------------------------------------------------------------
section "$LOG_UNASSIGNED" "SHARDS VRAIMENT NON ASSIGNES (UNASSIGNED)"
{
    echo "Ces shards n ont aucun noeud cible et ne sont pas en cours de replication."
    echo "Causes possibles : watermark disque, filtres d allocation, manque de noeuds."
    echo "Utiliser : GET /_cluster/allocation/explain pour diagnostiquer."
    echo ""
} >> "$LOG_UNASSIGNED"

if [ "$UNASSIGNED_COUNT" -eq 0 ]; then
    echo "✅ Aucun shard vraiment non assigne." >> "$LOG_UNASSIGNED"
else
    printf "⛔ %s shard(s) UNASSIGNED sans replication en cours\n\n" "$UNASSIGNED_COUNT" >> "$LOG_UNASSIGNED"
    print_shard_table "UNASSIGNED" "$LOG_UNASSIGNED"
fi
cat "$LOG_UNASSIGNED" >> "$LOG_MAIN"

# ------------------------------------------------------------------------------
# LOG : shards OK
# ------------------------------------------------------------------------------
section "$LOG_SAFE" "SHARDS OK - Au moins une copie survivante hors noeuds cibles"
{
    printf "✅ %s shard(s) avec replicas OK\n\n" "$SAFE_COUNT"
    eval printf "\"$SHARD_HEADER\"\n" $SHARD_COLS
    echo "$SEP_LINE"
    grep "^SAFE|" "$RISK_FILE" | awk -F'|' '{
        size_gb = sprintf("%.2f GB", $8/1024/1024/1024)
        printf "%-45s %-7s %-5s %-13s %-8s %-8s %-25s %-16s %s\n",
            $4, $5, $6, $7, $2, $3, $9, $10, size_gb
    }'
} >> "$LOG_SAFE"

# ------------------------------------------------------------------------------
# LOG : volumetrie totale des index concernes
# ------------------------------------------------------------------------------
section "$LOG_INDEX_VOL" "VOLUMETRIE TOTALE DES INDEX CONCERNES"
{
    echo "Source : _cat/indices (taille reelle incluant tous les shards et replicas)"
    echo "Colonnes :"
    echo "  PRI           : nombre de shards primaires"
    echo "  REP           : nombre de replicas configures"
    echo "  DOCS          : nombre de documents"
    echo "  TAILLE TOTALE : taille de tous les shards (primaires + replicas)"
    echo "  TAILLE PRI    : taille des primaires uniquement"
    echo "  STATUT        : risque detecte sur cet index"
    echo ""
    printf "%-45s %-5s %-5s %-12s %-16s %-16s %s\n" \
           "INDEX" "PRI" "REP" "DOCS" "TAILLE TOTALE" "TAILLE PRI" "STATUT"
    printf '%s\n' "$(printf '%0.s-' {1..125})"

    awk -F'|' -v risk_file="$RISK_FILE" '
        BEGIN {
            while ((getline line < risk_file) > 0) {
                split(line, f, "|")
                tag = f[1]; idx = f[4]
                if (tag == "RISK")        risk[idx]++
                if (tag == "REPLICATING") replic[idx]++
                if (tag == "UNASSIGNED")  unassign[idx]++
            }
        }
        {
            idx=$1; pri=$2; rep=$3; docs=$4
            size_total=$5; size_pri=$6

            size_total_gb = sprintf("%.2f GB", size_total/1024/1024/1024)
            size_pri_gb   = sprintf("%.2f GB", size_pri/1024/1024/1024)

            status = "OK"
            if (risk[idx]+0 > 0)     status = "RISQUE(" risk[idx] "sh)"
            if (replic[idx]+0 > 0)   status = status " REPLIC(" replic[idx] ")"
            if (unassign[idx]+0 > 0) status = status " UNASSIGN(" unassign[idx] ")"

            docs_fmt = (docs+0 > 1000000) ? sprintf("%.1fM", docs/1000000) \
                     : (docs+0 > 1000)    ? sprintf("%.1fK", docs/1000) \
                     : docs

            printf "%-45s %-5s %-5s %-12s %-16s %-16s %s\n",
                idx, pri, rep, docs_fmt, size_total_gb, size_pri_gb, status

            total_size += size_total
            total_pri  += size_pri
            total_idx++
        }
        END {
            printf "\n%-45s %-5s %-5s %-12s %-16s %-16s\n",
                "TOTAL (" total_idx " index)", "", "", "",
                sprintf("%.2f GB", total_size/1024/1024/1024),
                sprintf("%.2f GB", total_pri/1024/1024/1024)
        }
    ' "$INDEX_VOL_FILE" | sort -k6 -r

} | tee -a "$LOG_INDEX_VOL" >> "$LOG_MAIN"


# ------------------------------------------------------------------------------
# LOG : stats par noeud cible
# ------------------------------------------------------------------------------
section "$LOG_NODE_STATS" "REPARTITION PAR NOEUD CIBLE"
{
    printf "%-30s %-10s %-15s %-14s %s\n" \
           "NOEUD" "STARTED" "TAILLE TOTALE" "INITIALIZING" "AUTRES ETATS"
    printf '%s\n' "--------------------------------------------------------------------"
    awk -F'|' '{printf "%-30s %-10s %-15s %-14s %s\n",
        $1, $2, $3 " GB", $4, $5}' "$NODE_STATS_FILE"
} | tee -a "$LOG_NODE_STATS" >> "$LOG_MAIN"

# ------------------------------------------------------------------------------
# LOG : resume executif
# ------------------------------------------------------------------------------
{
    echo "RESULTATS"
    echo "---------"
    printf "  %-40s %s\n" "Shards a risque (copie unique STARTED) :" "$RISK_COUNT  ← DANGER"
    printf "  %-40s %s\n" "Shards en replication (INITIALIZING) :"   "$REPLIC_COUNT  ← pas encore proteges"
    printf "  %-40s %s\n" "Shards non assignes (UNASSIGNED) :"       "$UNASSIGNED_COUNT"
    printf "  %-40s %s\n" "  dont ATTENTE_NOEUD (auto) :"            "${COUNT_ATTENTE:-n/a}"
    printf "  %-40s %s\n" "  dont STALE (perte partielle) :"         "${COUNT_STALE:-n/a}  ← intervention manuelle"
    printf "  %-40s %s\n" "  dont PERDU (perte totale) :"            "${COUNT_PERDU:-n/a}  ← intervention manuelle"
    printf "  %-40s %s\n" "Shards OK (repliques ailleurs) :"         "$SAFE_COUNT"
    echo ""

    # Volumetrie totale des index concernes
    TOTAL_VOL=$(awk -F'|' '{sum+=$2} END {printf "%.2f", sum}' "$INDEX_VOL_FILE" 2>/dev/null || echo "?")
    printf "  %-40s %s GB\n" "Volume total des index concernes :" "$TOTAL_VOL"
    echo ""

    if [ "$RISK_COUNT" -gt 0 ] || [ "$REPLIC_COUNT" -gt 0 ]; then
        if [ "$RISK_COUNT" -gt 0 ]; then
            echo "⛔ MAINTENANCE BLOQUEE"
            echo "   $RISK_COUNT shard(s) en copie unique — perte de donnees certaine si le noeud s arrete"
        fi
        if [ "$REPLIC_COUNT" -gt 0 ]; then
            echo "⚠️  REPLICATION EN COURS : $REPLIC_COUNT shard(s) pas encore proteges"
            echo "   Attendre la fin de la replication puis relancer le diagnostic (--no-cache)"
        fi
        echo ""
        echo "   Actions requises :"
        echo "   1. Attendre fin replication : GET /_cat/shards?v | grep INITIALIZING"
        echo "   2. Augmenter replicas si necessaire : PUT /index/_settings"
        echo "      { \"index.number_of_replicas\": 1 }"
        echo "   3. Attendre green : GET /_cluster/health?wait_for_status=green&timeout=30m"
        echo "   4. Relancer : $0 $OS_HOST --no-cache $([ -n "$FILTER_TEMP" ] && echo "--temp $FILTER_TEMP") $([ -n "$FILTER_ZONE" ] && echo "--zone $FILTER_ZONE")"
        echo ""
        echo "   Index concernes (risque ou replication) :"
        grep -E "^(RISK|REPLICATING)\|" "$RISK_FILE" | \
            awk -F'|' '{print $4}' | sort -u | sed 's/^/     - /'
    elif [ "$UNASSIGNED_COUNT" -gt 0 ]; then
        echo "⚠️  ATTENTION : $UNASSIGNED_COUNT shard(s) UNASSIGNED sans replication"
        echo "   Ces shards ne sont sur aucun noeud."
        echo "   Diagnostiquer : GET /_cluster/allocation/explain"
    else
        echo "✅ MAINTENANCE POSSIBLE"
        echo "   Aucun shard en copie unique ni en cours de replication."
        echo "   Commande d exclusion recommandee avant arret :"
        echo "   PUT /_cluster/settings"
        echo "   { \"transient\": { \"cluster.routing.allocation.enable\": \"none\" } }"
    fi
    echo ""
    echo "Fichiers generes dans : $LOG_DIR"
    echo "  risk_shards.log        : shards en copie unique (DANGER)"
    echo "  replicating_shards.log : shards en cours de replication"
    echo "  unassigned_shards.log  : shards non assignes"
    echo "  unrecoverable_shards.log : classification ATTENTE/STALE/PERDU"
    [ "$NON_RECOV_TOTAL" -gt 0 ] && \
    echo "  remediation.log        : commandes curl pret-a-l-emploi"
    echo "  safe_shards.log        : shards OK"
    echo "  index_volumes.log      : volumetrie totale par index"
    echo "  node_stats.log         : repartition par noeud"
} | tee -a "$LOG_SUMMARY" >> "$LOG_MAIN"

# ------------------------------------------------------------------------------
# ETAPE 5 — Classification des shards UNASSIGNED NODE_LEFT
#           Integre depuis os_unrecoverable_shards.sh
#           Appel _cluster/allocation/explain pour chaque shard sans copie active
#           Categories : ATTENTE_NOEUD | STALE | PERDU
# ------------------------------------------------------------------------------

section "$LOG_UNRECOVERABLE" "ETAPE 5/5 - Classification des shards UNASSIGNED (recuperables vs perdus)"

# Extraire les shards tagués UNASSIGNED depuis l'analyse etape 4
# Format RISK_FILE : TAG|started|init|index|shard|role|state|store|node|ip
UNASSIGNED_FROM_ANALYSIS=$(grep "^UNASSIGNED|" "$RISK_FILE" 2>/dev/null || true)

if [ -z "$UNASSIGNED_FROM_ANALYSIS" ]; then
    echo "✅ Aucun shard UNASSIGNED a classifier." | tee -a "$LOG_UNRECOVERABLE" >> "$LOG_MAIN"
    COUNT_ATTENTE=0; COUNT_STALE=0; COUNT_PERDU=0
else
    TOTAL_TO_CLASSIFY=$(echo "$UNASSIGNED_FROM_ANALYSIS" | wc -l | tr -d ' ')
    log "Classification de $TOTAL_TO_CLASSIFY shard(s) UNASSIGNED via _cluster/allocation/explain"

    {
        echo "Methode : GET /_cluster/allocation/explain par shard"
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

    COUNT_ATTENTE=0; COUNT_STALE=0; COUNT_PERDU=0
    CACHE_STATE_DIR="$CACHE_DIR/cluster_state"
    mkdir -p "$CACHE_STATE_DIR"

    # ------------------------------------------------------------------
    # PHASE A : UN SEUL appel HTTP pour TOUS les index concernes
    #
    # On construit la liste CSV des index UNASSIGNED et on interroge
    # le cluster state en une seule requete :
    #   GET /_cluster/state/metadata,routing_table/idx1,idx2,...
    #
    # Puis UN SEUL awk parse le JSON et produit deux fichiers plats :
    #   insync_flat.txt  : index|shard|id1,id2,...
    #   routing_flat.txt : index|shard|allocation_id
    #
    # Aucune boucle shell, aucun fork supplementaire.
    # ------------------------------------------------------------------

    CACHE_STATE_DIR="$CACHE_DIR/cluster_state"
    mkdir -p "$CACHE_STATE_DIR"

    CACHE_STATE_ALL="$CACHE_STATE_DIR/all_indexes.json"
    CACHE_INSYNC="$CACHE_STATE_DIR/insync_flat.txt"
    CACHE_ROUTING="$CACHE_STATE_DIR/routing_flat.txt"

    # Liste CSV des index uniques ayant des shards UNASSIGNED
    INDEX_CSV=$(echo "$UNASSIGNED_FROM_ANALYSIS" \
        | awk -F'|' '{print $4}' | sort -u | tr '\n' ',' | sed 's/,$//')

    INDEX_COUNT=$(echo "$UNASSIGNED_FROM_ANALYSIS" \
        | awk -F'|' '{print $4}' | sort -u | wc -l | tr -d ' ')

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
            COUNT_ATTENTE=0; COUNT_STALE=0; COUNT_PERDU=0
        else
            log_ok "Cluster state fetche ($(wc -c < "$CACHE_STATE_ALL" | tr -d ' ') bytes)"
        fi
    else
        log "Cache cluster state valide"
    fi

    # ------------------------------------------------------------------
    # UN SEUL awk sur le JSON brut — construit insync_flat et routing_flat
    # en une passe, sans tr/sed/grep supplementaires.
    #
    # Strategie de parsing POSIX (sans match a 3 args) :
    #   - gsub pour isoler les valeurs
    #   - variables d etat pour suivre le contexte JSON
    #
    # insync_flat.txt  : index|shard|id1,id2,...
    # routing_flat.txt : index|shard|allocation_id
    # ------------------------------------------------------------------

    if [ -s "$CACHE_STATE_ALL" ] && \
       { ! cache_valid "$CACHE_INSYNC" || ! cache_valid "$CACHE_ROUTING"; }; then

        log "Parsing cluster state (un seul awk POSIX)..."

        awk '
            # ---- Detection du contexte index ----
            # Dans metadata.indices : "nom_index" : {
            /"indices"/ { in_indices_meta = 1 }

            in_indices_meta && /^ *"[^"]+": *\{/ {
                tmp = $0
                gsub(/^ *"/, "", tmp); gsub(/" *:.*/, "", tmp)
                # Ignorer les cles de structure connues
                if (tmp !~ /^(mappings|settings|aliases|in_sync_allocations|routing_table|shards|indices)$/ \
                    && length(tmp) > 0)
                    current_meta_idx = tmp
            }

            # ---- in_sync_allocations ----
            /"in_sync_allocations"/ { in_insync = 1; next }

            in_insync && /^ *"[0-9]+"/ {
                # Extraire le numero de shard : "0" : [...]
                tmp = $0
                gsub(/^ *"/, "", tmp)
                gsub(/".*/, "", tmp)
                insync_shard = tmp
            }

            in_insync && insync_shard != "" && /\[/ {
                # Extraire les ids entre [ ] sur la meme ligne ou multi-ligne
                tmp = $0
                gsub(/.*\[/, "", tmp); gsub(/\].*/, "", tmp)
                gsub(/"/, "", tmp);    gsub(/ /, "", tmp)
                # Supprimer virgules de tete/queue
                gsub(/^,/, "", tmp);   gsub(/,$/, "", tmp)
                if (tmp != "")
                    print current_meta_idx "|" insync_shard "|" tmp > insync_out
                insync_shard = ""
            }
            # Sortir du bloc in_sync quand on rencontre la fermeture
            in_insync && /^\s*\},?\s*$/ && insync_shard == "" { in_insync = 0 }

            # ---- routing_table ----
            /"routing_table"/ { in_routing = 1; in_indices_meta = 0 }

            # Detecter l index courant dans routing_table
            in_routing && /^ *"[^"]+": *\{/ {
                tmp = $0
                gsub(/^ *"/, "", tmp); gsub(/" *:.*/, "", tmp)
                if (tmp !~ /^(shards|routing_table|indices)$/ && length(tmp) > 0)
                    current_rt_idx = tmp
            }

            # Debut d un bloc shard
            in_routing && /"shard" *:/ {
                tmp = $0
                gsub(/.*"shard" *: */, "", tmp)
                gsub(/[^0-9].*/, "", tmp)
                rt_shard   = tmp
                rt_state   = ""
                rt_alloc   = "NONE"
                rt_primary = ""
            }

            in_routing && /"primary" *: *true/    { rt_primary = "true" }
            in_routing && /"state" *: *"UNASSIGNED"/ { rt_state = "UNASSIGNED" }

            # allocation_id.id — peut apparaitre apres "allocation_id" : {  "id" : "..."
            in_routing && rt_shard != "" && /"id" *: *"/ {
                tmp = $0
                gsub(/.*"id" *: *"/, "", tmp)
                gsub(/".*/, "", tmp)
                if (tmp != "") rt_alloc = tmp
            }

            # Fin de bloc shard — ecrire si primaire UNASSIGNED
            in_routing && /^\s*\},?\s*$/ && rt_primary == "true" && rt_state == "UNASSIGNED" {
                print current_rt_idx "|" rt_shard "|" rt_alloc > routing_out
                rt_primary = ""; rt_state = ""; rt_alloc = "NONE"; rt_shard = ""
            }

        ' insync_out="$CACHE_INSYNC" routing_out="$CACHE_ROUTING" "$CACHE_STATE_ALL"

        log_ok "Parsing termine — insync: $(wc -l < "$CACHE_INSYNC" | tr -d ' ') entrees, routing: $(wc -l < "$CACHE_ROUTING" | tr -d ' ') entrees"
    else
        log "Cache insync/routing valides — parsing ignore"
    fi

    # ------------------------------------------------------------------
    # PHASE B : Classification — 100% awk, zero fork, zero boucle shell
    #
    # Charge en memoire les deux tables :
    #   insync[index|shard]  = "id1,id2,..."
    #   routing[index|shard] = "allocation_id"
    #
    # Puis pour chaque ligne UNASSIGNED de l etape 4 :
    #   routing[k] absent ou NONE → PERDU
    #   routing[k] IN insync[k]   → ATTENTE_NOEUD
    #   routing[k] NOT IN insync  → STALE
    #
    # Les compteurs sont ecrits dans des fichiers tmp pour eviter
    # le sous-shell (les variables awk ne remontent pas dans bash
    # a travers un pipe).
    # ------------------------------------------------------------------

    log "Classification des shards UNASSIGNED (awk pur — zero fork)..."

    echo "$UNASSIGNED_FROM_ANALYSIS" | awk -F'|' \
        -v insync_file="$CACHE_INSYNC" \
        -v routing_file="$CACHE_ROUTING" \
        -v os_host="$OS_HOST" \
        -v log_unrec="$LOG_UNRECOVERABLE" \
        -v log_remed="$LOG_REMEDIATION" \
        -v cnt_file="$CACHE_STATE_DIR/counts.txt" \
    '
        BEGIN {
            # Charger insync en memoire : insync["index|shard"] = "id1,id2,..."
            while ((getline line < insync_file) > 0) {
                n = split(line, f, "|")
                if (n >= 3) insync[f[1] "|" f[2]] = f[3]
            }
            close(insync_file)

            # Charger routing en memoire : routing["index|shard"] = "alloc_id"
            while ((getline line < routing_file) > 0) {
                n = split(line, f, "|")
                if (n >= 3) routing[f[1] "|" f[2]] = f[3]
            }
            close(routing_file)

            cnt_attente = 0; cnt_stale = 0; cnt_perdu = 0
            fmt = "%-45s %-7s %-5s %-16s %-10s %s\n"
        }

        # Colonnes UNASSIGNED_FROM_ANALYSIS :
        # tag|started|init|index|shard|role|state|store|node|ip
        $1 == "UNASSIGNED" || $1 == "RISK" {
            idx   = $4; shard = $5; role  = $6; store = $8
            key   = idx "|" shard
            size_gb = sprintf("%.2f", (store + 0) / 1024 / 1024 / 1024)

            alloc_id   = (key in routing) ? routing[key] : "NONE"
            insync_ids = (key in insync)  ? insync[key]  : ""

            # --- Cas 1 : aucun allocation_id connu → perte totale ---
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
                next
            }

            # --- Cas 2 : shard absent de in_sync_allocations → perte totale ---
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
                next
            }

            # --- Cas 3 : croiser alloc_id avec la liste in_sync ---
            found = 0
            n = split(insync_ids, ids, ",")
            for (i = 1; i <= n; i++) {
                if (ids[i] == alloc_id) { found = 1; break }
            }

            if (found) {
                cnt_attente++
                detail = "alloc_id in_sync — recovery auto au retour du noeud"
                printf fmt, idx, shard, role, "ATTENTE", size_gb "GB", detail >> log_unrec
            } else {
                cnt_stale++
                detail = "alloc_id hors in_sync (id=" alloc_id ")"
                printf fmt, idx, shard, role, "STALE", size_gb "GB", detail >> log_unrec
                printf "# INDEX: %s | SHARD: %s | TAILLE: %sGB | PERTE PARTIELLE POSSIBLE\n", \
                    idx, shard, size_gb >> log_remed
                printf "# allocation_id=%s hors in_sync=%s\n", alloc_id, insync_ids >> log_remed
                printf "curl -ku admin:admin -X POST \"http://%s/_cluster/reroute\" \\\n", \
                    os_host >> log_remed
                printf "  -H \"Content-Type: application/json\" \\\n" >> log_remed
                printf "  -d \x27{\"commands\":[{\"allocate_stale_primary\":{\"index\":\"%s\",\"shard\":%s,\"node\":\"NOEUD_CIBLE\",\"accept_data_loss\":true}}]}\x27\n\n", \
                    idx, shard >> log_remed
            }
        }

        END {
            printf "%s|%s|%s\n", cnt_attente, cnt_stale, cnt_perdu > cnt_file
        }
    '

    # Recuperer les compteurs — ecrits par awk dans un fichier
    # (un pipe cree un sous-shell : les variables bash ne remonteraient pas)
    if [ -f "$CACHE_STATE_DIR/counts.txt" ]; then
        IFS='|' read -r COUNT_ATTENTE COUNT_STALE COUNT_PERDU \
            < "$CACHE_STATE_DIR/counts.txt"
    else
        COUNT_ATTENTE=0; COUNT_STALE=0; COUNT_PERDU=0
    fi

    log_ok "Classification terminee (ATTENTE=$COUNT_ATTENTE STALE=$COUNT_STALE PERDU=$COUNT_PERDU)"

    # Bilan etape 5
    {
        echo ""
        echo "--- Bilan de classification ---"
        printf "  ✅ ATTENTE_NOEUD : %-5s shard(s) — recovery auto au retour du noeud\n" "$COUNT_ATTENTE"
        printf "  ⚠️  STALE         : %-5s shard(s) — copie perimee, perte partielle possible\n" "$COUNT_STALE"
        printf "  🔴 PERDU          : %-5s shard(s) — aucune copie, perte totale\n" "$COUNT_PERDU"
        echo ""
        NON_RECOV=$((COUNT_STALE + COUNT_PERDU))
        if [ "$NON_RECOV" -gt 0 ]; then
            echo "⛔ $NON_RECOV shard(s) NON recuperables automatiquement"
            echo "   Voir : $LOG_REMEDIATION"
        else
            echo "✅ Tous les shards UNASSIGNED seront recuperes automatiquement"
            echo "   (au retour du/des noeud(s) absent(s))"
        fi
    } | tee -a "$LOG_UNRECOVERABLE" >> "$LOG_MAIN"

    log_ok "Etape 5 terminee (ATTENTE=$COUNT_ATTENTE STALE=$COUNT_STALE PERDU=$COUNT_PERDU)"
fi

# Compter les non recuperables pour le summary
NON_RECOV_TOTAL=$((${COUNT_STALE:-0} + ${COUNT_PERDU:-0}))

# ------------------------------------------------------------------------------
# Affichage final console
# ------------------------------------------------------------------------------
echo ""
echo "=================================================================="
log_ok "Diagnostic termine"
echo ""
echo "  📁 $LOG_DIR"
echo ""
printf "  %-30s %s\n"   "diagnostic.log"          "execution complete"
printf "  %-30s %s\n"   "nodes.log"               "noeuds decouverts / filtres"
printf "  %-30s %s (%s)\n" "risk_shards.log"         "shards DANGER"        "$RISK_COUNT"
printf "  %-30s %s (%s)\n" "replicating_shards.log"  "replication en cours"  "$REPLIC_COUNT"
printf "  %-30s %s (%s)\n" "unassigned_shards.log"   "non assignes"         "$UNASSIGNED_COUNT"
printf "  %-30s %s (attente=%-3s stale=%-3s perdu=%s)\n" \
    "unrecoverable_shards.log" "classification" \
    "${COUNT_ATTENTE:-0}" "${COUNT_STALE:-0}" "${COUNT_PERDU:-0}"
[ "$NON_RECOV_TOTAL" -gt 0 ] && \
printf "  %-30s %s (%s commandes)\n" "remediation.log" "commandes curl" "$NON_RECOV_TOTAL"
printf "  %-30s %s (%s)\n" "safe_shards.log"          "shards OK"            "$SAFE_COUNT"
printf "  %-30s %s\n"   "index_volumes.log"        "volumetrie par index"
printf "  %-30s %s\n"   "node_stats.log"           "stats par noeud cible"
printf "  %-30s %s\n"   "summary.log"              "resume executif"
[ -s "$LOG_ERRORS" ] && printf "  %-30s ⚠️\n" "errors.log"
echo ""
if   [ "$RISK_COUNT"       -gt 0 ]; then echo "  🔴 $RISK_COUNT shard(s) en copie unique       → maintenance BLOQUEE"
fi
if   [ "$REPLIC_COUNT"    -gt 0 ]; then echo "  ⚠️  $REPLIC_COUNT shard(s) en replication   → attendre avant maintenance"
fi
if   [ "${COUNT_STALE:-0}"  -gt 0 ]; then echo "  ⚠️  $COUNT_STALE shard(s) STALE             → allocate_stale_primary requis (voir remediation.log)"
fi
if   [ "${COUNT_PERDU:-0}"  -gt 0 ]; then echo "  🔴 $COUNT_PERDU shard(s) PERDU              → allocate_empty_primary requis (voir remediation.log)"
fi
if   [ "$RISK_COUNT" -eq 0 ] && [ "$REPLIC_COUNT" -eq 0 ] && \
     [ "${COUNT_STALE:-0}" -eq 0 ] && [ "${COUNT_PERDU:-0}" -eq 0 ]; then
    echo "  ✅ Aucun shard a risque ni non recuperable → maintenance possible"
fi
echo ""
echo "  Reprise : $0 $OS_HOST --resume --log-dir $LOG_DIR"
echo "=================================================================="

checkpoint_set "DONE"
