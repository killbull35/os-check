#!/usr/bin/awk -f
# Calculer la volumétrie depuis les shards (fallback)
# Usage: awk -f volumetrie_fallback.awk -v tfile=<target_nodes_file> shards_file
# Input: index shard prirep state store node ip segments.count
# Output: index|-|-|-|total_size|pri_size

BEGIN {
    FS = "|"
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
