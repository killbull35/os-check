#!/usr/bin/awk -f
# Filtrer les index concernés depuis _cat/indices
# Usage: awk -f filter_concerned_indices.awk -v cfile=<concerned_file> indices_file
# Input: index pri rep docs.count store.size pri.store.size
# Output: index|pri|rep|docs.count|store.size|pri.store.size (pour les index concernés)

BEGIN {
    FS = "|"
    while ((getline idx < cfile) > 0) concerned[idx] = 1
}

($1 in concerned) {
    printf "%s|%s|%s|%s|%s|%s\n", $1, $2, $3, $4, $5, $6
}
