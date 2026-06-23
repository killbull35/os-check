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
# ------------------------------------------------------------------------------
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
    awk '
        # --- Chargement des noeuds cibles ---
        NR==FNR {
            targets[$1] = 1
            next
        }

        # --- Comptage global par (index|shard) ---
        {
            key = $1 "|" $2
            state = $4

            if (state == "STARTED")      copies_started[key]++
            if (state == "INITIALIZING") copies_init[key]++

            # Stocker toutes les lignes par cle pour la passe END
            all_lines[key] = all_lines[key] $0 "\n"

            # Marquer si ce shard a au moins une copie sur un noeud cible
            if ($6 in targets) has_target[key] = 1
        }

        END {
            for (key in has_target) {
                n = split(all_lines[key], lines, "\n")
                started  = copies_started[key] + 0
                init     = copies_init[key]    + 0

                for (i = 1; i < n; i++) {
                    if (lines[i] == "") continue

                    # Re-parser la ligne
                    nf = split(lines[i], f, " ")
                    idx    = f[1]; shard = f[2]; role  = f[3]
                    state  = f[4]; store = f[5]; node  = f[6]
                    ip     = f[7]; segs  = f[8]

                    # Ligne de base du output
                    base = idx "|" shard "|" role "|" state "|" store "|" node "|" ip "|" segs

                    # Shard sur noeud cible
                    if (node in targets) {
                        if (state == "STARTED") {
                            tag = (started == 1) ? "RISK" : "SAFE"
                            print tag "|" started "|" init "|" base
                        } else if (state == "INITIALIZING") {
                            # Replication en cours sur le noeud cible lui-meme
                            print "REPLICATING|" started "|" init "|" base
                        } else {
                            # RELOCATING ou autre etat non nominal
                            tag = (started <= 1) ? "RISK" : "SAFE"
                            print tag "|" started "|" init "|" base
                        }
                    } else {
                        # Shard hors noeud cible mais appartient a un index
                        # dont au moins un shard est sur noeud cible
                        if (state == "INITIALIZING") {
                            # Replica en cours de copie depuis le primaire sur noeud cible
                            print "REPLICATING|" started "|" init "|" base
                        } else if (state == "UNASSIGNED") {
                            # Pas de noeud, pas encore en cours
                            print "UNASSIGNED|" started "|" init "|" base
                        }
                        # STARTED hors cible : on les ignore (ils sont la copie survivante)
                    }
                }
            }
        }
    ' "$TARGET_NODES_FILE" "$CACHE_SHARDS" > "$RISK_FILE"

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
RISK_COUNT=$(grep -c "^RISK|"        "$RISK_FILE" 2>/dev/null || echo 0)
SAFE_COUNT=$(grep -c "^SAFE|"        "$RISK_FILE" 2>/dev/null || echo 0)
REPLIC_COUNT=$(grep -c "^REPLICATING|" "$RISK_FILE" 2>/dev/null || echo 0)
UNASSIGNED_COUNT=$(grep -c "^UNASSIGNED|" "$RISK_FILE" 2>/dev/null || echo 0)

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
    # PHASE A : Fetch du cluster state par index (une seule fois par index)
    # Source de verite pour in_sync_allocations et allocation_id par shard
    #
    # Structure extraite depuis :
    #   GET /_cluster/state/metadata/{index}
    #
    # On construit un fichier plat par index :
    #   shard_num|alloc_id_1,alloc_id_2,...   (in_sync_allocations)
    #
    # Et depuis routing_table :
    #   GET /_cluster/state/routing_table/{index}
    # On extrait pour chaque shard UNASSIGNED son allocation_id connu
    #   shard_num|node_id|allocation_id
    # ------------------------------------------------------------------

    # Collecter les index uniques a traiter
    INDEXES_TO_FETCH=$(echo "$UNASSIGNED_FROM_ANALYSIS" \
        | awk -F'|' '{print $4}' | sort -u)

    INDEX_COUNT=$(echo "$INDEXES_TO_FETCH" | wc -l | tr -d ' ')
    log "Fetch cluster state pour $INDEX_COUNT index uniques"

    for idx in $INDEXES_TO_FETCH; do
        # Fichier cache par index — in_sync : "shard|id1,id2,..."
        INSYNC_CACHE="$CACHE_STATE_DIR/${idx}.insync"
        # Fichier cache par index — routing : "shard|node|alloc_id"
        ROUTING_CACHE="$CACHE_STATE_DIR/${idx}.routing"

        if cache_valid "$INSYNC_CACHE" && cache_valid "$ROUTING_CACHE"; then
            continue
        fi

        # Fetch metadata (in_sync_allocations)
        META_JSON=$(${CURL}_cluster/state/metadata/${idx}?pretty 2>/dev/null)

        if [ -z "$META_JSON" ]; then
            log_warn "cluster state metadata non disponible pour $idx"
            touch "$INSYNC_CACHE" "$ROUTING_CACHE"
            continue
        fi

        # Parser in_sync_allocations depuis le JSON shell pur
        # Format attendu :
        #   "in_sync_allocations": { "0": ["id1","id2"], "1": ["id3"] }
        # On produit : shard_num|id1,id2,...
        echo "$META_JSON" \
            | tr '{' '\n' | tr '}' '\n' \
            | awk '
                /"in_sync_allocations"/ { in_block=1; next }
                in_block && /"[0-9]+"/ {
                    # Extraire le numero de shard
                    match($0, /"([0-9]+)"/, arr)
                    shard_num = arr[1]
                    # Extraire tous les IDs entre crochets
                    gsub(/.*\[/, ""); gsub(/\].*/, "")
                    gsub(/"/, ""); gsub(/ /, "")
                    print shard_num "|" $0
                }
                in_block && /^\s*\}/ { in_block=0 }
            ' > "$INSYNC_CACHE"

        # Fetch routing_table (allocation_id par shard)
        ROUTE_JSON=$(${CURL}_cluster/state/routing_table/${idx}?pretty 2>/dev/null)

        if [ -z "$ROUTE_JSON" ]; then
            log_warn "cluster state routing_table non disponible pour $idx"
            touch "$ROUTING_CACHE"
            continue
        fi

        # Parser routing_table — on cherche les shards UNASSIGNED avec un allocation_id
        # Format produit : shard_num|node (ou NONE)|allocation_id (ou NONE)
        echo "$ROUTE_JSON" \
            | tr '{' '\n' | tr '}' '\n' \
            | awk '
                /"shard"/ {
                    match($0, /"shard" *: *([0-9]+)/, a); shard_num = a[1]
                    node = "NONE"; alloc_id = "NONE"; state = ""
                }
                /"state"/ && /"UNASSIGNED"/ { state = "UNASSIGNED" }
                /"node"/ {
                    match($0, /"node" *: *"([^"]+)"/, a); node = a[1]
                }
                /"allocation_id"/ {
                    # allocation_id peut etre sur la ligne suivante
                    match($0, /"id" *: *"([^"]+)"/, a)
                    if (a[1] != "") alloc_id = a[1]
                }
                /"primary" *: *true/ && state == "UNASSIGNED" {
                    print shard_num "|" node "|" alloc_id
                }
            ' > "$ROUTING_CACHE"

    done
    log_ok "Cluster state fetche pour tous les index concernes"

    # ------------------------------------------------------------------
    # PHASE B : Classification shard par shard
    # Croisement allocation_id (routing_table) vs in_sync_allocations
    #
    # Logique :
    #   1. Recuperer allocation_id du shard depuis routing_table
    #   2. Verifier si cet id est dans la liste in_sync du shard
    #      OUI  → le noeud absent avait une copie valide → ATTENTE_NOEUD
    #      NON  → copie presente mais perimee            → STALE
    #      NONE → aucun id connu dans les metadonnees    → PERDU
    # ------------------------------------------------------------------

    while IFS='|' read -r tag started init idx shard role state store node ip; do
        [ -z "$idx" ] && continue

        SIZE_GB=$(awk -v s="$store" 'BEGIN {printf "%.2f", (s+0)/1024/1024/1024}')

        INSYNC_CACHE="$CACHE_STATE_DIR/${idx}.insync"
        ROUTING_CACHE="$CACHE_STATE_DIR/${idx}.routing"

        # Recuperer l allocation_id du shard depuis routing_table
        ALLOC_ID=$(grep "^${shard}|" "$ROUTING_CACHE" 2>/dev/null \
            | head -1 | awk -F'|' '{print $3}')

        if [ -z "$ALLOC_ID" ] || [ "$ALLOC_ID" = "NONE" ]; then
            # Aucun allocation_id dans les metadonnees de routage → perte totale
            CLASSIF="PERDU"
            COUNT_PERDU=$((COUNT_PERDU + 1))
            DETAIL="Aucun allocation_id dans le routing_table"
            printf "%-45s %-7s %-5s %-16s %-10s %s\n" \
                "$idx" "$shard" "$role" "🔴 PERDU" "${SIZE_GB}GB" "$DETAIL" \
                >> "$LOG_UNRECOVERABLE"
            {
                echo "# INDEX: $idx | SHARD: $shard | TAILLE: ${SIZE_GB}GB | PERTE TOTALE"
                printf 'curl -ku admin:admin -X POST "http://%s/_cluster/reroute" \\\n' "$OS_HOST"
                printf '  -H "Content-Type: application/json" \\\n'
                printf "  -d '{\"commands\":[{\"allocate_empty_primary\":{\"index\":\"%s\",\"shard\":%s,\"node\":\"NOEUD_CIBLE\",\"accept_data_loss\":true}}]}'\n" \
                    "$idx" "$shard"
                echo ""
            } >> "$LOG_REMEDIATION"
            continue
        fi

        # Verifier si cet allocation_id est dans la liste in_sync du shard
        # INSYNC_CACHE contient : shard_num|id1,id2,...
        INSYNC_IDS=$(grep "^${shard}|" "$INSYNC_CACHE" 2>/dev/null \
            | head -1 | awk -F'|' '{print $2}')

        if [ -z "$INSYNC_IDS" ]; then
            # Shard absent des in_sync_allocations → aucune copie valide connue
            CLASSIF="PERDU"
            COUNT_PERDU=$((COUNT_PERDU + 1))
            DETAIL="Shard absent de in_sync_allocations"
            printf "%-45s %-7s %-5s %-16s %-10s %s\n" \
                "$idx" "$shard" "$role" "🔴 PERDU" "${SIZE_GB}GB" "$DETAIL" \
                >> "$LOG_UNRECOVERABLE"
            {
                echo "# INDEX: $idx | SHARD: $shard | TAILLE: ${SIZE_GB}GB | PERTE TOTALE"
                printf 'curl -ku admin:admin -X POST "http://%s/_cluster/reroute" \\\n' "$OS_HOST"
                printf '  -H "Content-Type: application/json" \\\n'
                printf "  -d '{\"commands\":[{\"allocate_empty_primary\":{\"index\":\"%s\",\"shard\":%s,\"node\":\"NOEUD_CIBLE\",\"accept_data_loss\":true}}]}'\n" \
                    "$idx" "$shard"
                echo ""
            } >> "$LOG_REMEDIATION"
            continue
        fi

        # Chercher si l'allocation_id du shard figure dans in_sync
        # (la liste peut contenir plusieurs ids separes par virgule)
        IS_IN_SYNC=$(echo "$INSYNC_IDS" | tr ',' '\n' \
            | grep -c "^${ALLOC_ID}$" 2>/dev/null || echo 0)

        if [ "$IS_IN_SYNC" -gt 0 ]; then
            # allocation_id trouve dans in_sync_allocations → copie valide sur noeud absent
            CLASSIF="ATTENTE_NOEUD"
            COUNT_ATTENTE=$((COUNT_ATTENTE + 1))
            DETAIL="alloc_id in_sync — recovery auto au retour du noeud"
            printf "%-45s %-7s %-5s %-16s %-10s %s\n" \
                "$idx" "$shard" "$role" "✅ ATTENTE" "${SIZE_GB}GB" "$DETAIL" \
                >> "$LOG_UNRECOVERABLE"
        else
            # allocation_id connu mais absent de in_sync → copie perimee
            CLASSIF="STALE"
            COUNT_STALE=$((COUNT_STALE + 1))
            DETAIL="alloc_id hors in_sync_allocations (id=$ALLOC_ID)"
            printf "%-45s %-7s %-5s %-16s %-10s %s\n" \
                "$idx" "$shard" "$role" "⚠️  STALE" "${SIZE_GB}GB" "$DETAIL" \
                >> "$LOG_UNRECOVERABLE"
            {
                echo "# INDEX: $idx | SHARD: $shard | TAILLE: ${SIZE_GB}GB | PERTE PARTIELLE POSSIBLE"
                echo "# allocation_id=$ALLOC_ID hors in_sync=$INSYNC_IDS"
                printf 'curl -ku admin:admin -X POST "http://%s/_cluster/reroute" \\\n' "$OS_HOST"
                printf '  -H "Content-Type: application/json" \\\n'
                printf "  -d '{\"commands\":[{\"allocate_stale_primary\":{\"index\":\"%s\",\"shard\":%s,\"node\":\"NOEUD_CIBLE\",\"accept_data_loss\":true}}]}'\n" \
                    "$idx" "$shard"
                echo ""
            } >> "$LOG_REMEDIATION"
        fi

    done <<< "$UNASSIGNED_FROM_ANALYSIS"

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
