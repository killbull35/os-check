#!/usr/bin/awk -f
# Construire rep_flat.txt depuis _cat/indices
# Input: index pri rep docs.count store.size pri.store.size
# Output: index|rep

{
    print $1 "|" $3
}
