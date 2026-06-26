#!/usr/bin/awk -f
# Parser le cluster state pour extraire in_sync_allocations et routing_table
# Usage: awk -f parse_cluster_state.awk insync_out=<file> routing_out=<file> state_file
# Input: JSON from _cluster/state/metadata,routing_table
# Output: in_sync_allocations -> insync_out, routing_table -> routing_out

# ---- Detection du contexte index ---
/"indices"/ { in_indices_meta = 1 }

in_indices_meta && /^ *"[^"]+": *\{/ {
    tmp = $0
    gsub(/^ *"/, "", tmp); gsub(/".*/, "", tmp)
    if (tmp !~ /^(mappings|settings|aliases|in_sync_allocations|routing_table|shards|indices)$/ \
        && length(tmp) > 0)
        current_meta_idx = tmp
}

# ---- in_sync_allocations ---
/"in_sync_allocations"/ { in_insync = 1; next }

in_insync && /^ *"[0-9]+"/ {
    tmp = $0
    gsub(/^ *"/, "", tmp)
    gsub(/".*/, "", tmp)
    insync_shard = tmp
}

in_insync && insync_shard != "" && /\[/ {
    tmp = $0
    gsub(/.*\[/, "", tmp); gsub(/\].*/, "", tmp)
    gsub(/"/, "", tmp);    gsub(/ /, "", tmp)
    gsub(/^,/, "", tmp);   gsub(/,$/, "", tmp)
    if (tmp != "")
        print current_meta_idx "|" insync_shard "|" tmp > insync_out
    insync_shard = ""
}
in_insync && /^\s*\},?\s*$/ && insync_shard == "" { in_insync = 0 }

# ---- routing_table ---
/"routing_table"/ { in_routing = 1; in_indices_meta = 0 }

in_routing && /^ *"[^"]+": *\{/ {
    tmp = $0
    gsub(/^ *"/, "", tmp); gsub(/".*/, "", tmp)
    if (tmp !~ /^(shards|routing_table|indices)$/ && length(tmp) > 0)
        current_rt_idx = tmp
}

in_routing && /"shard" *:/ {
    tmp = $0
    gsub(/.*"shard" *: */, "", tmp)
    gsub(/[^0-9].*/, "", tmp)
    rt_shard = tmp
    rt_state = ""
    rt_alloc = "NONE"
    rt_primary = ""
    rt_node = ""
}

in_routing && /"primary" *: *true/    { rt_primary = "true" }
in_routing && /"state" *: *"UNASSIGNED"/ { rt_state = "UNASSIGNED" }
in_routing && /"node" *: *"[^"]+"/ {
    tmp = $0
    gsub(/.*"node" *: *"/, "", tmp)
    gsub(/".*/, "", tmp)
    rt_node = tmp
}

in_routing && rt_shard != "" && /"id" *: *"/ {
    tmp = $0
    gsub(/.*"id" *: *"/, "", tmp)
    gsub(/".*/, "", tmp)
    if (tmp != "") rt_alloc = tmp
}

in_routing && /^\s*\},?\s*$/ && rt_primary == "true" && rt_state == "UNASSIGNED" {
    print current_rt_idx "|" rt_shard "|" rt_alloc "|" rt_node > routing_out
    rt_primary = ""; rt_state = ""; rt_alloc = "NONE"; rt_shard = ""; rt_node = ""
}
