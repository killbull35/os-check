#!/usr/bin/awk -f
# Calculer le volume total pour un statut donné
# Usage: awk -f calc_volume.awk -v status=<STATUT> file
# Input: format variable selon le fichier
# Output: volume en GB

BEGIN {
    FS = "|"
    sum = 0
}

# Pour LOG_UNRECOVERABLE (format: INDEX SHARD ROLE CLASSIFICATION TAILLE DETAIL...)
/status/ {
    # La taille est en colonne 5 (format "X.XXGB" ou "X.XX")
    size_val = $5
    gsub(/GB/, "", size_val)
    if (size_val ~ /^[0-9.]+$/) {
        sum += size_val + 0
    }
}

END {
    printf "%.2f GB", sum
}
