#!/usr/bin/awk -f
# Extraire les zones ou temps uniques
# Usage: awk -f extract_zones_temps.awk -v field=<2|3> file
# Input: name|zone|temp
# Output: zone ou temp unique

BEGIN {
    FS = "|"
}
{
    print $field
}
