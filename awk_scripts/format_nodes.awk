#!/usr/bin/awk -f
# Formater l'affichage des nodes
# Input: name|zone|temp
# Output: formaté pour affichage

BEGIN {
    FS = "|"
    printf "%-30s %-10s %s\n", "NOM", "TEMP", "ZONE"
    printf '%s\n', "----------------------------------------------------"
}
{
    printf "%-30s %-10s %s\n", $1, $3, $2
}
