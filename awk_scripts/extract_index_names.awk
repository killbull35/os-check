#!/usr/bin/awk -f
# Extraire les noms d'index depuis UNASSIGNED_FROM_ANALYSIS
# Extraire uniquement le premier mot du 4ème champ (au cas où il contient des espaces)
# Input: tag|started|init|index|shard|role|state|store|node|ip
# Output: index (premier mot seulement)

BEGIN {
    FS = "|"
}
{
    # Extraire uniquement le premier mot du champ index
    split($4, idx_parts, " ")
    print idx_parts[1]
}
