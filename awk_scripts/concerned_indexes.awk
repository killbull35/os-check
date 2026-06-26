#!/usr/bin/awk -f
# Extraire les index concernés depuis les shards STARTED sur les nodes cibles
# Usage: awk -f concerned_indexes.awk -v tfile=<target_nodes_file> shards_file
# Input: index shard prirep state store node ip segments.count
# Output: index (un par ligne)

BEGIN {
    FS = "|"
    while ((getline node < tfile) > 0) targets[node]=1
}

$4=="STARTED" && ($6 in targets) { concerned[$1] = 1 }

END { for (idx in concerned) print idx }
