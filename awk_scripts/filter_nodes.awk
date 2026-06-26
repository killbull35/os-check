#!/usr/bin/awk -f
# Filtrer les noeuds par temp et zone
# Usage: awk -f filter_nodes.awk -v ft="<temp>" -v fz="<zone>" nodes_file
# Input: name|zone|temp
# Output: name (filtré)

BEGIN {
    FS = "|"
}
{
    name = $1; zone = $2; temp = $3
    if (ft != "" && temp != ft) next
    if (fz != "" && zone != fz) next
    print name
}
