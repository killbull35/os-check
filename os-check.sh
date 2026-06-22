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

echo ""
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