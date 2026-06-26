#!/usr/bin/awk -f
# Parse OpenSearch nodes JSON to extract name, zone, temp
# Input: JSON from _nodes?filter_path=nodes.*.name,nodes.*.attributes
# Output: name|zone|temp

BEGIN { 
    RS=","; 
    FS="\"" 
}

/"name"/ && !/attr/ {
    if (name != "") print name "|" zone "|" temp
    for(i=1;i<=NF;i++) if($i=="name") { name=$(i+2); break }
    zone="-"; temp="-"
}

/"zone"/ { 
    for(i=1;i<=NF;i++) if($i=="zone") { zone=$(i+2); break } 
}

/"temp"/ { 
    for(i=1;i<=NF;i++) if($i=="temp") { temp=$(i+2); break } 
}

END { 
    if (name != "") print name "|" zone "|" temp 
}
