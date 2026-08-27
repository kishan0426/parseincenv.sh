#!/bin/bash

if [ -z "$1" ]; then
  echo "Usage: $0 <path_to_ora600_trace_file>"
  exit 1
fi

INPUT_FILE="$1"

awk '
# Function to classify parameters into categories
function get_category(param) {
    if (param ~ /^(parallel|px_|_px)/) return "Parallel Execution"
    if (param ~ /^(optimizer|(_optimizer)|_query_rewrite|_unnest|_push|_complex)/) return "Optimizer & Transformation"
    if (param ~ /^(inmemory|_inmemory)/) return "In-Memory"
    if (param ~ /^(cell|_cell)/) return "Exadata & Cell Offload"
    if (param ~ /^(hash|sort|bitmap|pga|workarea|_smm)/) return "Memory & Workarea"
    return "General / Other"
}

# Function to invert boolean or status values
function invert_value(val) {
    gsub(/^[ \t]+|[ \t]+$/, "", val)
    LVAL = tolower(val)
    if (LVAL == "true")  return "false"
    if (LVAL == "false") return "true"
    if (LVAL == "enabled")  return "disabled"
    if (LVAL == "disabled") return "enabled"
    if (LVAL == "on")    return "off"
    if (LVAL == "off")   return "on"
    return val
}

# Dynamically trigger capture when line matches "Compilation Environment Dump" regardless of TOC number
$0 ~ /Compilation Environment Dump/ { capturing = 1; next }

# Stop capturing when encountering the next TOC section marker
capturing && /^\[TOC[0-9]+\]/ { capturing = 0 }

{
    if (!capturing) next

    line = $0
    gsub(/^[ \t]+|[ \t]+$/, "", line)

    # Skip empty lines or trailing end markers
    if (line == "" || line ~ /-END$/) next

    # Expecting format: "parameter_name = value"
    if (line ~ /=/) {
        n = split(line, arr, "=")
        if (n >= 2) {
            p_name = arr[1]
            p_val  = arr[2]
            gsub(/^[ \t]+|[ \t]+$/, "", p_name)
            gsub(/^[ \t]+|[ \t]+$/, "", p_val)
            
            # Filter out non-parameter strings
            if (p_name ~ /^[a-zA-Z0-9_]+$/) {
                inv_val = invert_value(p_val)
                cat = get_category(p_name)
                
                idx = ++count[cat]
                data[cat, idx] = p_name "=" inv_val
            }
        }
    }
}

END {
    n_cats = 6
    cats[1] = "Parallel Execution"
    cats[2] = "Optimizer & Transformation"
    cats[3] = "Memory & Workarea"
    cats[4] = "In-Memory"
    cats[5] = "Exadata & Cell Offload"
    cats[6] = "General / Other"

    print "REM ========================================================"
    print "REM ALTER SESSION Script generated dynamically"
    print "REM Values have been inverted (true <-> false, etc.)"
    print "REM ========================================================"
    print ""

    for (c = 1; c <= 6; c++) {
        cat_name = cats[c]
        if (count[cat_name] > 0) {
            print "-- ----------------------------------------------------"
            print "-- Category: " cat_name
            print "-- ----------------------------------------------------"
            
            for (i = 1; i <= count[cat_name]; i++) {
                split(data[cat_name, i], pair, "=")
                p = pair[1]
                v = pair[2]
                
                if (v ~ /^[0-9.]+$/ || v == "true" || v == "false" || v == "on" || v == "off" || v == "enabled" || v == "disabled") {
                    print "ALTER SESSION SET " p " = " v ";"
                } else {
                    print "ALTER SESSION SET " p " = \x27" v "\x27;"
                }
            }
            print ""
        }
    }
}
' "$INPUT_FILE"
