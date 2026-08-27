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

# --- Pass 1: Capture Current SQL Statement dynamically ---
/----- Current SQL Statement for this session/ {
    capturing_sql = 1
    # Extract sql_id if present on the same line
    if (match($0, /sql_id=([a-zA-Z0-9]+)/, arr)) {
        sql_id_val = arr[1]
    }
    next
}
capturing_sql && /^\[TOC[0-9]+\]/ { capturing_sql = 0 }
capturing_sql {
    if ($0 ~ /^sql_id=/) {
        if (match($0, /sql_id=([a-zA-Z0-9]+)/, arr)) sql_id_val = arr[1]
    } else {
        if (sql_text == "") sql_text = $0
        else sql_text = sql_text " " $0
    }
}

# --- Pass 2: Capture Call Stack Trace & Highlight Error Functions ---
/----- Call Stack Trace -----/ { capturing_stack = 1; next }
capturing_stack && /--------------------/ { stack_header_seen = 1; next }
capturing_stack && stack_header_seen {
    if ($0 ~ /^\[TOC/ || $0 ~ /^---/ || $0 == "") {
        capturing_stack = 0
    } else {
        if ($0 ~ /call/) {
            for (i=1; i<=NF; i++) {
                if ($i ~ /\(\)$/) {
                    fn = $i
                    if (fn ~ /^(kxfpProcessError|kgereml|kxfpProcessMsg)\(\)$/) {
                        fn = "***" fn "***"
                    }

                    if (stack_funcs == "") stack_funcs = fn
                    else stack_funcs = fn " -> " stack_funcs
                }
            }
        }
    }
}

# Capture error frame info for summary banner
/FRAME \[[0-9]+\]/ {
    frame_line = $0
    getline next_line
    if (next_line ~ /ERROR SIGNALED: yes/) {
        error_frame_info = frame_line " [" next_line "]"
    }
}

# --- Pass 3: Capture Compilation Environment Dump dynamically ---
$0 ~ /Compilation Environment Dump/ { capturing_env = 1; next }
capturing_env && /^\[TOC[0-9]+\]/ { capturing_env = 0 }

{
    if (!capturing_env) next

    line = $0
    gsub(/^[ \t]+|[ \t]+$/, "", line)

    if (line == "" || line ~ /-END$/) next

    if (line ~ /=/) {
        n = split(line, arr, "=")
        if (n >= 2) {
            p_name = arr[1]
            p_val  = arr[2]
            gsub(/^[ \t]+|[ \t]+$/, "", p_name)
            gsub(/^[ \t]+|[ \t]+$/, "", p_val)
            
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
    print "REM ========================================================"
    print "REM ORA-600 Incident Analysis Report"
    print "REM ========================================================"
    print ""

    if (sql_text != "") {
        print "-- ----------------------------------------------------"
        print "-- Problematic SQL Statement (SQL_ID: " (sql_id_val ? sql_id_val : "UNKNOWN") "):"
        print "-- ----------------------------------------------------"
        # Wrap sql text nicely across comments
        print "REM " sql_text
        print ""
    }
    
    if (error_frame_info != "") {
        print "-- ----------------------------------------------------"
        print "-- [***] HIGHLIGHTED ERROR FRAME (Root Cause Signal):"
        print "-- ----------------------------------------------------"
        print "REM " error_frame_info
        print ""
    }

    if (stack_funcs != "") {
        print "-- ----------------------------------------------------"
        print "-- Refined Call Stack Flow (Highlighted with ***):"
        print "-- ----------------------------------------------------"
        print "REM " stack_funcs
        print ""
    }

    n_cats = 6
    cats[1] = "Parallel Execution"
    cats[2] = "Optimizer & Transformation"
    cats[3] = "Memory & Workarea"
    cats[4] = "In-Memory"
    cats[5] = "Exadata & Cell Offload"
    cats[6] = "General / Other"

    print "REM ========================================================"
    print "REM Generated ALTER SESSION Script with Inverted Values"
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
                
                # Enclose parameter name in double quotes universally
                quoted_p = "\"" p "\""
                
                if (v ~ /^[0-9.]+$/ || v == "true" || v == "false" || v == "on" || v == "off" || v == "enabled" || v == "disabled") {
                    print "ALTER SESSION SET " quoted_p " = " v ";"
                } else {
                    print "ALTER SESSION SET " quoted_p " = \x27" v "\x27;"
                }
            }
            print ""
        }
    }
}
' "$INPUT_FILE"
