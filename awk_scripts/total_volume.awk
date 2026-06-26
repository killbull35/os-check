#!/usr/bin/awk -f
# Calculer le volume total depuis les shards
# Usage: awk -f total_volume.awk shards_file
# Input: index shard prirep state store node ip segments.count
# Output: volume total en GB

BEGIN {
    FS = "|"
    sum = 0
}
{
    sum += $5
}

END {
    printf "%.2f GB", sum/1024/1024/1024
}
