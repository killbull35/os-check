#!/usr/bin/awk -f
# Calculer les stats par noeud cible
# Usage: awk -f node_stats.awk -v tfile=<target_nodes_file> shards_file
# Input: index shard prirep state store node ip segments.count
# Output: node|count|size_gb|init_count|other_count

BEGIN {
    FS = "|"
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
