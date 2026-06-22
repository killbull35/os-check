#!/usr/bin/env bash
# Diagnostic shards a risque - version optimisee
# - Zéro fork dans les boucles (tout en awk)
# - Cache fichier des appels API
# - Reprise sur erreur via checkpoints
# - LC_ALL=C pour compatibilite decimale
export LC_ALL=C
export LANG=C

# ---------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------
OS_HOST="localhost:9200"
FILTER_TEMP=""
FILTER_ZONE=""
CACHE_DIR="/tmp/os_diag_cache"
CHECKPOINT_FILE="$CACHE_DIR/checkpoint"
CACHE_TTL=300   # secondes avant re-fetch (5 min)
# AUTH="-u admin:password"
# CURL_OPTS="-k"

# ---------------------------------------------------------------
# Parsing arguments
# ---------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --temp)       FILTER_TEMP="$2";  shift 2 ;;
        --zone)       FILTER_ZONE="$2";  shift 2 ;;
        --no-cache)   FORCE_REFRESH=1;   shift   ;;
        --resume)     RESUME=1;          shift   ;;
        --cache-dir)  CACHE_DIR="$2";    shift 2 ;;
        *) OS_HOST="$1"; shift ;;
    esac
done

CURL="curl -s --max-time 30 --retry 3 --retry-delay 2 ${AUTH} ${CURL_OPTS} http://${OS_HOST}"
CACHE_NODES="$CACHE_DIR/nodes.json"
CACHE_SHARDS="$CACHE_DIR/shards.txt"
CACHE_NODES_PARSED="$CACHE_DIR/nodes_parsed.txt"

mkdir -p "$CACHE_DIR"

# ---------------------------------------------------------------
# Fonctions utilitaires
# ---------------------------------------------------------------

log()       { echo "[$(date '+%H:%M:%S')] $*"; }
log_ok()    { echo "[$(date '+%H:%M:%S')] ✅ $*"; }
log_warn()  { echo "[$(date '+%H:%M:%S')] ⚠️  $*"; }
log_err()   { echo "[$(date '+%H:%M:%S')] 🔴 $*" >&2; }

checkpoint_set() { echo "$1" > "$CHECKPOINT_FILE"; }
checkpoint_get() { [ -f "$CHECKPOINT_FILE" ] && cat "$CHECKPOINT_FILE" || echo ""; }

# Vérifie si un cache est encore valide
cache_valid() {
    local file="$1"
    [ -z "$FORCE_REFRESH" ] || return 1
    [ -f "$file" ] || return 1
    local age=$(( $(date +%s) - $(date -r "$file" +%s 2>/dev/null || echo 0) ))
    [ "$age" -lt "$CACHE_TTL" ]
}

# Appel API avec retry et validation
api_fetch() {
    local url="$1"
    local cache_file="$2"
    local description="$3"

    if cache_valid "$cache_file"; then
        log "Cache valide pour $description ($(wc -c < "$cache_file") bytes)"
        return 0
    fi

    log "Fetch $description..."
    local tmp="$cache_file.tmp"
    local http_code

    http_code=$(${CURL} -w "%{http_code}" -o "$tmp" "$url")

    if [ "$http_code" != "200" ] || [ ! -s "$tmp" ]; then
        log_err "Echec fetch $description (HTTP $http_code)"
        rm -f "$tmp"
        # Utiliser le cache expiré si disponible plutôt que d'échouer
        if [ -f "$cache_file" ]; then
            log_warn "Utilisation du cache expire pour $description"
            return 0
        fi
        return 1
    fi

    mv "$tmp" "$cache_file"
    log_ok "$description fetché ($(wc -c < "$cache_file") bytes)"
}

# ---------------------------------------------------------------
# Header
# ---------------------------------------------------------------
echo "=================================================================="
echo " Diagnostic shards a risque - $(date)"
echo " Host      : $OS_HOST"
echo " Cache dir : $CACHE_DIR (TTL=${CACHE_TTL}s)"
[ -n "$FILTER_TEMP" ] && echo " Filtre temp : $FILTER_TEMP"
[ -n "$FILTER_ZONE" ] && echo " Filtre zone : $FILTER_ZONE"
echo "=================================================================="

# ---------------------------------------------------------------
# Reprise sur erreur
# ---------------------------------------------------------------
LAST_CHECKPOINT=$(checkpoint_get)
if [ -n "$RESUME" ] && [ -n "$LAST_CHECKPOINT" ]; then
    log "Reprise depuis checkpoint : $LAST_CHECKPOINT"
else
    checkpoint_set "START"
    LAST_CHECKPOINT="START"
fi

# ---------------------------------------------------------------
# ETAPE 1 — Noeuds
# ---------------------------------------------------------------
if [ "$LAST_CHECKPOINT" = "START" ] || [ "$LAST_CHECKPOINT" = "NODES" ]; then

    echo ""
    log "ETAPE 1/4 : Decouverte des noeuds"
    checkpoint_set "NODES"

    api_fetch \
        "/_nodes?filter_path=nodes.*.name,nodes.*.attributes" \
        "$CACHE_NODES" \
        "noeuds" || { log_err "Abandon etape 1"; exit 1; }

    # Parsing JSON → fichier plat "nom|zone|temp"
    # Tout en un seul awk, zero fork supplementaire
    awk '
        BEGIN { RS=","; FS="\"" }
        /"name"/ && !/attr/ {
            if (name != "") print name "|" zone "|" temp
            # extraire la valeur apres "name":"..."
            for(i=1;i<=NF;i++) if($i=="name") { name=$(i+2); break }
            zone="-"; temp="-"
        }
        /"zone"/ { for(i=1;i<=NF;i++) if($i=="zone") { zone=$(i+2); break } }
        /"temp"/ { for(i=1;i<=NF;i++) if($i=="temp") { temp=$(i+2); break } }
        END { if (name != "") print name "|" zone "|" temp }
    ' "$CACHE_NODES" > "$CACHE_NODES_PARSED"

    if [ ! -s "$CACHE_NODES_PARSED" ]; then
        log_err "Aucun noeud parse. Verifiez node.attr.zone / node.attr.temp"
        exit 1
    fi

    NODE_TOTAL=$(wc -l < "$CACHE_NODES_PARSED" | tr -d ' ')
    log_ok "$NODE_TOTAL noeud(s) decouverts"

    printf "\n%-30s %-10s %s\n" "NOM" "TEMP" "ZONE"
    printf '%s\n' "----------------------------------------------------"
    awk -F'|' '{printf "%-30s %-10s %s\n", $1, $3, $2}' "$CACHE_NODES_PARSED"

    checkpoint_set "NODES_DONE"
fi

# ---------------------------------------------------------------
# ETAPE 2 — Filtrage des noeuds cibles
# ---------------------------------------------------------------
if [ "$LAST_CHECKPOINT" != "SHARDS_DONE" ] && \
   [ "$LAST_CHECKPOINT" != "ANALYSIS_DONE" ]; then

    echo ""
    log "ETAPE 2/4 : Filtrage des noeuds (temp=$FILTER_TEMP zone=$FILTER_ZONE)"

    TARGET_NODES_FILE="$CACHE_DIR/target_nodes.txt"

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
        log_err "Aucun noeud ne correspond aux filtres"
        exit 1
    fi

    NODE_COUNT=$(wc -l < "$TARGET_NODES_FILE" | tr -d ' ')
    log_ok "$NODE_COUNT noeud(s) cible(s) :"
    sed 's/^/  - /' "$TARGET_NODES_FILE"

    checkpoint_set "FILTER_DONE"
fi

# ---------------------------------------------------------------
# ETAPE 3 — Récupération des shards
# ---------------------------------------------------------------
if [ "$LAST_CHECKPOINT" != "SHARDS_DONE" ] && \
   [ "$LAST_CHECKPOINT" != "ANALYSIS_DONE" ]; then

    echo ""
    log "ETAPE 3/4 : Recuperation des shards (peut etre long sur 14k shards)"

    api_fetch \
        "/_cat/shards?h=index,shard,prirep,state,store,node&bytes=b" \
        "$CACHE_SHARDS" \
        "shards" || { log_err "Abandon etape 3"; exit 1; }

    SHARD_TOTAL=$(wc -l < "$CACHE_SHARDS" | tr -d ' ')
    log_ok "$SHARD_TOTAL shards recuperes"

    checkpoint_set "SHARDS_DONE"
fi

# ---------------------------------------------------------------
# ETAPE 4 — Analyse (100% awk, zero fork en boucle)
# ---------------------------------------------------------------
echo ""
log "ETAPE 4/4 : Analyse des risques (awk pur sur $SHARD_TOTAL shards)"
checkpoint_set "ANALYSIS_RUNNING"

RISK_FILE="$CACHE_DIR/risk_shards.txt"
NODE_STATS_FILE="$CACHE_DIR/node_stats.txt"

# Un seul passage awk sur les deux fichiers :
# - Fichier 1 (target_nodes.txt) : construit le set des noeuds cibles
# - Fichier 2 (shards.txt)       : deux passes
#   Passe A : compter les copies de chaque shard dans le cluster entier
#   Passe B : identifier les shards sur noeuds cibles avec copie unique
#
# NR==FNR = premier fichier (target_nodes)
# NR!=FNR = deuxieme fichier (shards)

awk '
    # --- Chargement des noeuds cibles ---
    NR==FNR {
        targets[$1] = 1
        next
    }

    # --- Passe sur les shards ---
    # Compter toutes les copies STARTED par (index,shard)
    $4 == "STARTED" {
        key = $1 "|" $2
        copies[key]++
        # Si ce shard est sur un noeud cible, le stocker
        if ($6 in targets) {
            on_target[key] = on_target[key] $1 "|" $2 "|" $3 "|" $5 "|" $6 "\n"
        }
    }

    END {
        for (key in on_target) {
            n = split(on_target[key], lines, "\n")
            for (i=1; i<n; i++) {
                if (copies[key] == 1)
                    print "RISK|" lines[i]
                else
                    print "OK|" lines[i]
            }
        }
    }
' "$TARGET_NODES_FILE" "$CACHE_SHARDS" > "$RISK_FILE"

# Stats par noeud (second awk sur le fichier de shards, ciblé)
awk -v tfile="$TARGET_NODES_FILE" '
    BEGIN {
        while ((getline node < tfile) > 0) targets[node]=1
    }
    $4=="STARTED" && ($6 in targets) {
        count[$6]++
        size[$6] += $5
    }
    END {
        for (n in count)
            printf "%-30s %-10s %.2f\n", n, count[n], size[n]/1024/1024/1024
    }
' "$CACHE_SHARDS" > "$NODE_STATS_FILE"

checkpoint_set "ANALYSIS_DONE"

# ---------------------------------------------------------------
# Affichage des résultats
# ---------------------------------------------------------------
echo ""
echo "--- Shards a risque (copie unique) ---"
echo ""

RISK_COUNT=$(grep -c "^RISK|" "$RISK_FILE" 2>/dev/null || echo 0)

if [ "$RISK_COUNT" -eq 0 ]; then
    log_ok "Aucun shard a risque. Maintenance possible."
else
    log_err "$RISK_COUNT shard(s) en copie unique — perte de donnees possible"
    echo ""
    printf "%-50s %-8s %-6s %-12s %s\n" "INDEX" "SHARD" "ROLE" "TAILLE" "NOEUD"
    printf '%s\n' "$(printf '%0.s-' {1..100})"

    grep "^RISK|" "$RISK_FILE" | awk -F'|' '{
        size_gb = $5/1024/1024/1024
        printf "%-50s %-8s %-6s %-12s %s\n", $2, $3, $4, sprintf("%.2f GB", size_gb), $6
    }'

    echo ""
    echo "--- Recapitulatif par index ---"
    printf "%-50s %-18s %s\n" "INDEX" "SHARDS A RISQUE" "TAILLE TOTALE"
    printf '%s\n' "$(printf '%0.s-' {1..80})"

    grep "^RISK|" "$RISK_FILE" | awk -F'|' '{
        count[$2]++
        size[$2] += $5
    }
    END {
        for (i in count)
            printf "%-50s %-18s %.2f GB\n", i, count[i], size[i]/1024/1024/1024
    }' | sort -k2 -rn
fi

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
#   ./os_risk_diag.sh localhost:9200 --zone az2 --log-dir /var/log/opensearch
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
# Build a suffix that reflects filter parameters for reproducible logs
FILTER_SUFFIX=""
[[ -n "$FILTER_TEMP" ]] && FILTER_SUFFIX+="_temp-${FILTER_TEMP}"
[[ -n "$FILTER_ZONE" ]] && FILTER_SUFFIX+="_zone-${FILTER_ZONE}"
# Use a generic suffix when no filter is supplied
[[ -z "$FILTER_SUFFIX" ]] && FILTER_SUFFIX="_all"
LOG_DIR="/tmp/os_diag${FILTER_SUFFIX}_$(date '+%Y%m%d_%H%M%S')"
CACHE_TTL=300         # secondes avant re-fetch (5 min)
# AUTH="-u admin:motdepasse"
# CURL_OPTS="-k"      # si TLS auto-signe

# ------------------------------------------------------------------------------
# Parsing des arguments
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --temp)      FILTER_TEMP="$2";  shift 2 ;;
        --zone)      FILTER_ZONE="$2";  shift 2 ;;
        --no-cache)  FORCE_REFRESH=1;   shift   ;;
        --resume)    RESUME=1;          shift   ;;
        --log-dir)   LOG_DIR="$2";      shift 2 ;;
        *) OS_HOST="$1"; shift ;;
    esac
done

# En mode resume, chercher le dernier run si LOG_DIR n'a pas ete fourni
if [ -n "$RESUME" ] && [ ! -d "$LOG_DIR" ]; then
    LAST_RUN=$(ls -1dt /tmp/os_diag_* 2>/dev/null | head -1)
    if [ -n "$LAST_RUN" ]; then
        LOG_DIR="$LAST_RUN"
        echo "Resume detecte : utilisation du repertoire $LOG_DIR"
    fi
fi

mkdir -p "$LOG_DIR"

# ------------------------------------------------------------------------------
# Fichiers de log par nature
# ------------------------------------------------------------------------------
LOG_MAIN="$LOG_DIR/diagnostic.log"          # log principal (tout)
LOG_NODES="$LOG_DIR/nodes.log"              # tableau des noeuds découverts
LOG_RISK="$LOG_DIR/risk_shards.log"         # shards en copie unique (DANGER)
LOG_SAFE="$LOG_DIR/safe_shards.log"         # shards avec replicas OK
LOG_NODE_STATS="$LOG_DIR/node_stats.log"    # repartition par noeud
LOG_SUMMARY="$LOG_DIR/summary.log"          # resume executif
LOG_ERRORS="$LOG_DIR/errors.log"            # erreurs uniquement

# Fichiers internes (cache/checkpoint)
CACHE_DIR="$LOG_DIR/cache"
CHECKPOINT_FILE="$CACHE_DIR/checkpoint"
CACHE_NODES="$CACHE_DIR/nodes.json"
CACHE_SHARDS="$CACHE_DIR/shards.txt"
CACHE_NODES_PARSED="$CACHE_DIR/nodes_parsed.txt"
TARGET_NODES_FILE="$CACHE_DIR/target_nodes.txt"
RISK_FILE="$CACHE_DIR/risk_analysis.txt"
NODE_STATS_FILE="$CACHE_DIR/node_stats.txt"

mkdir -p "$CACHE_DIR"

# Construction de la base curl — URL sans espace : ${CURL}/${endpoint}
CURL="curl -s --max-time 30 --retry 3 --retry-delay 2 ${AUTH} ${CURL_OPTS} http://${OS_HOST}"

# ------------------------------------------------------------------------------
# Fonctions utilitaires
# ------------------------------------------------------------------------------

# Ecriture dans le log principal ET sur stdout
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

# Ecriture dans un fichier de log specifique + log principal
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

# Appel API avec retry, validation HTTP et fallback cache expire
api_fetch() {
    local endpoint="$1"
    local cache_file="$2"
    local description="$3"
    # URL construite sans espace
    local url="${CURL}/${endpoint}"

    if cache_valid "$cache_file"; then
        log "Cache valide pour $description ($(wc -c < "$cache_file") bytes)"
        return 0
    fi

    log "Fetch $description via /${endpoint} ..."
    local tmp="${cache_file}.tmp"
    local http_code

    http_code=$(${CURL}/${endpoint} -w "%{http_code}" -o "$tmp")

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

# Ecriture d'un separateur de section dans un fichier log
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
RUN_DATE=$(date '+%Y-%m-%d %H:%M:%S')
{
    echo "=================================================================="
    echo " Diagnostic shards a risque OpenSearch"
    echo " Date      : $RUN_DATE"
    echo " Host      : $OS_HOST"
    echo " Log dir   : $LOG_DIR"
    echo " Cache TTL : ${CACHE_TTL}s"
    [ -n "$FILTER_TEMP" ] && echo " Filtre temp : $FILTER_TEMP"
    [ -n "$FILTER_ZONE" ] && echo " Filtre zone : $FILTER_ZONE"
    echo "=================================================================="
    echo ""
    echo "Fichiers de log generes :"
    echo "  diagnostic.log   -> log complet de l'execution"
    echo "  nodes.log        -> noeuds decouverts et filtres"
    echo "  risk_shards.log  -> shards en copie unique (DANGER)"
    echo "  safe_shards.log  -> shards avec replicas OK"
    echo "  node_stats.log   -> repartition par noeud cible"
    echo "  summary.log      -> resume executif"
    echo "  errors.log       -> erreurs uniquement"
    echo ""
} | tee "$LOG_MAIN"

# Initialiser le summary
{
    echo "RESUME EXECUTIF - Diagnostic OpenSearch"
    echo "Date    : $RUN_DATE"
    echo "Host    : $OS_HOST"
    [ -n "$FILTER_TEMP" ] && echo "Filtre temp : $FILTER_TEMP"
    [ -n "$FILTER_ZONE" ] && echo "Filtre zone : $FILTER_ZONE"
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

    # Parsing JSON → fichier plat "nom|zone|temp" — un seul awk, zero fork
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

    # Ecriture dans nodes.log
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

    log "ETAPE 3/4 : Recuperation des shards du cluster"
    checkpoint_set "SHARDS_RUNNING"

    # On recupere egalement routing.state et le segment pour avoir
    # la localisation complete : index, shard, role, state, store, node, ip, segment
    api_fetch \
        "_cat/shards?h=index,shard,prirep,state,store,node,ip,segments.count&bytes=b&s=index,shard" \
        "$CACHE_SHARDS" \
        "shards" || { log_err "Abandon etape 3"; exit 1; }

    SHARD_TOTAL=$(wc -l < "$CACHE_SHARDS" | tr -d ' ')
    log_ok "$SHARD_TOTAL shards recuperes"
    echo "Total shards cluster : $SHARD_TOTAL" >> "$LOG_SUMMARY"

    checkpoint_set "SHARDS_DONE"
    LAST_CHECKPOINT="SHARDS_DONE"
fi

# ------------------------------------------------------------------------------
# ETAPE 4 — Analyse (100% awk, zero fork en boucle)
# ------------------------------------------------------------------------------
if [ "$LAST_CHECKPOINT" = "SHARDS_DONE" ]; then

    log "ETAPE 4/4 : Analyse des risques (awk pur)"
    checkpoint_set "ANALYSIS_RUNNING"

    # Un seul passage awk sur les deux fichiers :
    # FNR==NR  → premier fichier  : target_nodes.txt → set des noeuds cibles
    # FNR!=NR  → deuxieme fichier : shards.txt
    #   Passe 1 : compter toutes les copies STARTED par (index|shard)
    #             et stocker la localisation complete de chaque shard
    #   Passe 2 (END) : distinguer RISK / SAFE selon nb de copies

    awk '
        # Chargement des noeuds cibles
        NR==FNR {
            targets[$1] = 1
            next
        }

        # Shards : compter les copies STARTED dans tout le cluster
        # Colonnes : index shard prirep state store node ip segments.count
        $4 == "STARTED" {
            key = $1 "|" $2
            copies[key]++
        }

        # Shards sur noeuds cibles : stocker la ligne complete
        $4 == "STARTED" && ($6 in targets) {
            key = $1 "|" $2
            # Stocker chaque shard avec toutes ses infos de localisation
            entry = $1 "|" $2 "|" $3 "|" $4 "|" $5 "|" $6 "|" $7 "|" $8
            on_target[key] = on_target[key] entry "\n"
        }

    # Shards non STARTED sur noeuds cibles (INITIALIZING, UNASSIGNED)
    $4 == "INITIALIZING" && ($6 in targets) {
        key = $1 "|" $2
        entry = $1 "|" $2 "|" $3 "|" $4 "|" $5 "|" $6 "|" $7 "|" $8
        replicating[key] = replicating[key] entry "\n"
    }
    $4 == "UNASSIGNED" && ($6 in targets) {
        key = $1 "|" $2
        entry = $1 "|" $2 "|" $3 "|" $4 "|" $5 "|" $6 "|" $7 "|" $8
        not_started[key] = not_started[key] entry "\n"
    }
    # RELOCATING shards are already on target node and are considered safe (they already have data)
    $4 == "RELOCATING" && ($6 in targets) {
        key = $1 "|" $2
        entry = $1 "|" $2 "|" $3 "|" $4 "|" $5 "|" $6 "|" $7 "|" $8
        on_target[key] = on_target[key] entry "\n"
    }

    END {
        # Shards on target nodes (STARTED and RELOCATING are safe)
        for (key in on_target) {
            n = split(on_target[key], lines, "\n")
            for (i = 1; i < n; i++) {
                if (lines[i] == "") continue
                tag = (copies[key] == 1) ? "RISK" : "SAFE"
                print tag "|" copies[key] "|" lines[i]
            }
        }
        # Replicating shards (INITIALIZING) – separate tag
        for (key in replicating) {
            n = split(replicating[key], lines, "\n")
            for (i = 1; i < n; i++) {
                if (lines[i] == "") continue
                tag = (copies[key] <= 1) ? "RISK" : "REPLICATING"
                print tag "|" copies[key] "|" lines[i]
            }
    }
    # Shards non demarres sur noeuds cibles (UNASSIGNED)
    for (key in not_started) {
        n = split(not_started[key], lines, "\n")
        for (i = 1; i < n; i++) {
            if (lines[i] == "") continue
            tag = (copies[key] <= 1) ? "RISK" : "WARN"
            print tag "|" copies[key] "|" lines[i]
        }
    }
}
        }
    }
    ' "$TARGET_NODES_FILE" "$CACHE_SHARDS" > "$RISK_FILE"

    # Stats par noeud cible
    awk '
        BEGIN {
            while ((getline node < tfile) > 0) targets[node]=1
        }
        $4=="STARTED" && ($6 in targets) {
            count[$6]++
            size[$6] += $5
        }
        $4!="STARTED" && ($6 in targets) {
            not_started[$6]++
        }
        END {
            for (n in count)
                printf "%s|%s|%.2f|%s\n", n, count[n], size[n]/1024/1024/1024, (not_started[n]+0)
        }
    ' tfile="$TARGET_NODES_FILE" "$CACHE_SHARDS" > "$NODE_STATS_FILE"

    checkpoint_set "ANALYSIS_DONE"
    LAST_CHECKPOINT="ANALYSIS_DONE"
fi

# ------------------------------------------------------------------------------
# GENERATION DES FICHIERS DE LOG PAR NATURE
# ------------------------------------------------------------------------------

RISK_COUNT=$(grep -c "^RISK|" "$RISK_FILE" 2>/dev/null || echo 0)
WARN_COUNT=$(grep -c "^WARN|" "$RISK_FILE" 2>/dev/null || echo 0)
SAFE_COUNT=$(grep -c "^SAFE|" "$RISK_FILE" 2>/dev/null || echo 0)
REPLICATING_COUNT=$(grep -c "^REPLICATING|" "$RISK_FILE" 2>/dev/null || echo 0)

# --- LOG : shards a risque (copie unique) ---
section "$LOG_RISK" "SHARDS A RISQUE - Copie unique (perte de donnees possible)"
{
    echo "Legende colonnes :"
    echo "  INDEX       : nom de l index"
    echo "  SHARD       : numero du shard"
    echo "  ROLE        : p=primaire r=replica"
    echo "  ETAT        : etat actuel du shard (STARTED / INITIALIZING / UNASSIGNED...). RELOCATING shards are considered safe and are not listed here."
    echo "  COPIES      : nombre de copies STARTED dans le cluster"
    echo "  NOEUD       : noeud hebergeant le shard"
    echo "  IP          : adresse IP du noeud"
    echo "  TAILLE      : taille du shard"
    echo "  SEGMENTS    : nombre de segments Lucene"
    echo ""
} >> "$LOG_RISK"

if [ "$RISK_COUNT" -eq 0 ]; then
    echo "✅ Aucun shard a risque detecte." | tee -a "$LOG_RISK" >> "$LOG_MAIN"
    echo "   Toutes les donnees ont au moins une copie survivante ailleurs." | tee -a "$LOG_RISK" >> "$LOG_MAIN"
else
    {
        printf "🔴 %s shard(s) en COPIE UNIQUE\n\n" "$RISK_COUNT"
        printf "%-45s %-7s %-5s %-13s %-7s %-25s %-16s %-12s %s\n" \
               "INDEX" "SHARD" "ROLE" "ETAT" "COPIES" "NOEUD" "IP" "TAILLE" "SEGMENTS"
        printf '%s\n' "$(printf '%0.s-' {1..150})"
    } | tee -a "$LOG_RISK" >> "$LOG_MAIN"

    grep "^RISK|" "$RISK_FILE" | awk -F'|' '{
        size_gb = sprintf("%.2f GB", $7/1024/1024/1024)
        printf "%-45s %-7s %-5s %-13s %-7s %-25s %-16s %-12s %s\n",
               $3, $4, $5, $6, $2, $8, $9, size_gb, $10
    }' | tee -a "$LOG_RISK" >> "$LOG_MAIN"

    # Recapitulatif par index dans le log risque
    {
        echo ""
        echo "--- Recapitulatif par index ---"
        printf "%-45s %-18s %s\n" "INDEX" "SHARDS A RISQUE" "TAILLE EXPOSEE"
        printf '%s\n' "$(printf '%0.s-' {1..80})"
    } | tee -a "$LOG_RISK" >> "$LOG_MAIN"

    grep "^RISK|" "$RISK_FILE" | awk -F'|' '{
        count[$3]++
        size[$3] += $7
    }
    END {
        for (i in count)
            printf "%-45s %-18s %.2f GB\n", i, count[i], size[i]/1024/1024/1024
    }' | sort -t'|' -k2 -rn | tee -a "$LOG_RISK" >> "$LOG_MAIN"
fi

# --- LOG : shards REPLICATING (INITIALIZING) ---
section "$LOG_RISK" "SHARDS EN REPLICATION - Initializing (données en cours de réplication)"
{
    printf "%s\n" "Ces shards sont en état INITIALIZING ; la réplication n'est pas encore terminée."
    printf "%45s %7s %5s %13s %7s %25s %16s %12s %s\n" \
        "INDEX" "SHARD" "ROLE" "ETAT" "COPIES" "NOEUD" "IP" "TAILLE" "SEGMENTS"
    printf '%s\n' "$(printf '%0.s-' {1..150})"
}

grep "^REPLICATING|^RISK" "$RISK_FILE" | awk -F'|' '{
    size_gb = sprintf("%.2f GB", $7/1024/1024/1024)
    printf "%45s %7s %5s %13s %7s %25s %16s %12s %s\n", $3,$4,$5,$6,$2,$8,$9,size_gb,$10
}' | tee -a "$LOG_RISK" >> "$LOG_MAIN"

# Shards WARN (non STARTED sur noeuds cibles)
if [ "$WARN_COUNT" -gt 0 ]; then
    {
        echo ""
        echo "--- Shards non STARTED sur noeuds cibles ($WARN_COUNT) ---"
        printf "%-45s %-7s %-5s %-13s %-7s %-25s %s\n" \
               "INDEX" "SHARD" "ROLE" "ETAT" "COPIES" "NOEUD" "IP"
        printf '%s\n' "$(printf '%0.s-' {1..120})"
        grep "^WARN|" "$RISK_FILE" | awk -F'|' '{
            printf "%-45s %-7s %-5s %-13s %-7s %-25s %s\n",
                   $3, $4, $5, $6, $2, $8, $9
        }'
    } | tee -a "$LOG_RISK" >> "$LOG_MAIN"
fi

# --- LOG : shards OK ---
section "$LOG_SAFE" "SHARDS OK - Au moins une copie survivante hors noeuds cibles"
{
    printf "%-45s %-7s %-5s %-13s %-7s %-25s %-16s %s\n" \
           "INDEX" "SHARD" "ROLE" "ETAT" "COPIES" "NOEUD" "IP" "TAILLE"
    printf '%s\n' "$(printf '%0.s-' {1..130})"

    grep "^SAFE|" "$RISK_FILE" | awk -F'|' '{
        size_gb = sprintf("%.2f GB", $7/1024/1024/1024)
        printf "%-45s %-7s %-5s %-13s %-7s %-25s %-16s %s\n",
               $3, $4, $5, $6, $2, $8, $9, size_gb
    }'
    echo ""
    echo "Total : $SAFE_COUNT shard(s) avec replicas OK"
} >> "$LOG_SAFE"
log "Log shards OK : $LOG_SAFE ($SAFE_COUNT shards)"

# --- LOG : stats par noeud ---
section "$LOG_NODE_STATS" "REPARTITION PAR NOEUD CIBLE"
{
    printf "%-30s %-10s %-15s %s\n" "NOEUD" "SHARDS" "TAILLE TOTALE" "NON STARTED"
    printf '%s\n' "----------------------------------------------------"
    awk -F'|' '{printf "%-30s %-10s %-15s %s\n", $1, $2, $3 " GB", $4}' "$NODE_STATS_FILE"
} | tee -a "$LOG_NODE_STATS" >> "$LOG_MAIN"

# --- LOG : resume executif ---
{
    echo ""
    echo "RESULTATS"
    echo "---------"
    echo "Shards a risque (copie unique) : $RISK_COUNT  ← DANGER si maintenance"
    echo "Shards en cours de réplication (INITIALIZING) : $REPLICATING_COUNT"
    echo "Shards non STARTED sur cibles  : $WARN_COUNT"
    echo "Shards OK (replicas ailleurs)  : $SAFE_COUNT"
    echo ""
    if [ "$RISK_COUNT" -gt 0 ]; then
        echo "⛔ MAINTENANCE BLOQUEE : $RISK_COUNT shard(s) en copie unique"
        echo "   Actions requises avant de continuer :"
        echo "   1. Augmenter number_of_replicas sur les index concernes"
        echo "   2. Attendre la replication (GET _cluster/health?wait_for_status=green)"
        echo "   3. Relancer ce diagnostic (--no-cache)"
        echo ""
        echo "Index concernes :"
        grep "^RISK|" "$RISK_FILE" | awk -F'|' '{print $3}' | sort -u | sed 's/^/  - /'
    else
        echo "✅ MAINTENANCE POSSIBLE : aucun shard en copie unique"
        echo "   Commande d exclusion du noeud recommandee :"
        echo "   PUT /_cluster/settings"
        echo "   { \"transient\": { \"cluster.routing.allocation.exclude._name\": \"<noeud>\" } }"
    fi
    echo ""
    echo "Fichiers generes dans : $LOG_DIR"
    echo "  risk_shards.log  : details des shards dangereux"
    echo "  safe_shards.log  : shards avec replicas OK"
    echo "  node_stats.log   : repartition par noeud"
    echo "  nodes.log        : noeuds decouverts"
    echo "  errors.log       : erreurs rencontrees"
} | tee -a "$LOG_SUMMARY" >> "$LOG_MAIN"

# ------------------------------------------------------------------------------
# Affichage final console
# ------------------------------------------------------------------------------
echo ""
echo "=================================================================="
log_ok "Diagnostic termine"
echo ""
echo "  📁 Logs generes dans : $LOG_DIR"
echo ""
printf "  %-25s %s\n" "diagnostic.log"  "-> execution complete"
printf "  %-25s %s\n" "nodes.log"       "-> noeuds decouverts / filtres"
printf "  %-25s %s (%s lignes)" "risk_shards.log" "-> shards DANGER" "$RISK_COUNT"
# show replicating count if present
if [ "$REPLICATING_COUNT" -gt 0 ]; then
    printf "  %-25s %s (%s lignes)" "risk_shards.log" "-> shards EN REPLICATION" "$REPLICATING_COUNT"
    echo ""
fi

echo ""
printf "  %-25s %s (%s lignes)" "safe_shards.log" "-> shards OK" "$SAFE_COUNT"
echo ""
printf "  %-25s %s\n" "node_stats.log"  "-> stats par noeud cible"
printf "  %-25s %s\n" "summary.log"     "-> resume executif"
[ -s "$LOG_ERRORS" ] && printf "  %-25s %s ⚠️\n" "errors.log" "-> erreurs detectees"
echo ""
if [ "$RISK_COUNT" -gt 0 ]; then
    echo "  🔴 $RISK_COUNT shard(s) en copie unique — maintenance BLOQUEE"
    echo "     Voir : $LOG_RISK"
    if [ "$REPLICATING_COUNT" -gt 0 ]; then
        echo "  🔄 $REPLICATING_COUNT shard(s) en cours de réplication (INITIALIZING)"
        echo "     Voir : $LOG_RISK"
    fi
else
    echo "  ✅ Aucun shard a risque — maintenance possible"
fi
echo ""
echo "  Reprise possible avec : $0 $OS_HOST --resume --log-dir $LOG_DIR"
echo "=================================================================="

checkpoint_set "DONE"echo ""
echo "--- Repartition par noeud cible ---"
printf "%-30s %-10s %s\n" "NOEUD" "SHARDS" "TAILLE TOTALE"
printf '%s\n' "----------------------------------------------------"
awk '{printf "%-30s %-10s %s GB\n", $1, $2, $3}' "$NODE_STATS_FILE"

echo ""
echo "=================================================================="
log_ok "Diagnostic termine. Cache conserve dans $CACHE_DIR"
echo "    Relancer avec --no-cache pour forcer un refresh"
echo "    Relancer avec --resume en cas d'interruption"
echo "=================================================================="

checkpoint_set "DONE"