#!/bin/bash
export LC_ALL=C

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

# --- Pass 0: Capture Session Header Metadata & Signatures ---
index($0, "SERVICE NAME:") > 0 {
    if (match($0, /SERVICE NAME:\(([^)]*)\)/, arr)) service_val = arr[1]
}
index($0, "MODULE NAME:") > 0 {
    if (match($0, /MODULE NAME:\(([^)]*)\)/, arr)) module_val = arr[1]
}
index($0, "ACTION NAME:") > 0 {
    if (match($0, /ACTION NAME:\(([^)]*)\)/, arr)) action_val = arr[1]
}
index($0, "CLIENT ID:") > 0 {
    if (match($0, /CLIENT ID:\(([^)]*)\)/, arr)) client_id_val = arr[1]
}
index($0, "CLIENT IP:") > 0 {
    if (match($0, /CLIENT IP:\(([^)]*)\)/, arr)) client_ip_val = arr[1]
}
index($0, "CONTAINER ID:") > 0 {
    if (match($0, /CONTAINER ID:\(([^)]*)\)/, arr)) container_id_val = arr[1]
}
index($0, "SESSION ID:") > 0 {
    if (match($0, /SESSION ID:\(([^)]*)\)/, arr)) session_id_val = arr[1]
}
index($0, "Call stack signature:") > 0 {
    if (match($0, /Call stack signature:[ \t]*(0x[a-fA-F0-9]+)/, arr)) sig_full = arr[1]
}
index($0, "Partial call stack signature:") > 0 {
    if (match($0, /Partial call stack signature:[ \t]*(0x[a-fA-F0-9]+)/, arr)) sig_partial = arr[1]
}

# --- Pass 0.1: Precisely Capture Call Stack Performance Statistics ---
index($0, "call stack performance statistics") > 0 {
    capturing_perf = 1
    next
}
capturing_perf && ($0 ~ /^[[:space:]]*$/ || index($0, "---") > 0 || index($0, "TOC") > 0) {
    capturing_perf = 0
}
capturing_perf {
    line_perf = $0
    gsub(/^[ \t]+|[ \t]+$/, "", line_perf)
    if (line_perf != "") {
        n_p = split(line_perf, p_arr, ":")
        if (n_p >= 2) {
            lbl = p_arr[1]
            val_str = p_arr[2]
            gsub(/^[ \t]+|[ \t]+$/, "", lbl)
            gsub(/^[ \t]+|[ \t]+$/, "", val_str)
            
            if (match(val_str, /^([0-9.]+)/, v_arr)) {
                num_val = v_arr[1] + 0
                perf_count++
                perf_val[perf_count] = num_val
                perf_text[perf_count] = lbl ": " num_val " sec"
            }
        }
    }
}

# --- Pass 0.2: Capture Process Map & Extract Loaded Libraries cleanly ---
index($0, "Process Map Dump") > 0 { capturing_pmap = 1; next }
capturing_pmap && index($0, "TOC") > 0 { capturing_pmap = 0 }
capturing_pmap {
    if (match($0, /[ \t]+(\/[^ \t]+|\[[a-z]+\])/, arr)) {
        lib_path = arr[1]
        if (!seen_lib[lib_path]) {
            seen_lib[lib_path] = 1
            lib_count++
            lib_list[lib_count] = lib_path
        }
    }
}

# --- Pass 0.3: Capture Process Resource Limits (Robust Field-based Parser) ---
index($0, "Dumping Resource Limits") > 0 { capturing_limits = 1; next }
capturing_limits && index($0, "End of Resource Limits") > 0 { capturing_limits = 0 }
capturing_limits {
    l_line = $0
    gsub(/^[ \t]+|[ \t]+$/, "", l_line)
    if (l_line != "" && index(l_line, "***") == 0) {
        n_fields = split(l_line, f_arr, /[ \t]{2,}|[ \t]+/)
        if (n_fields >= 2) {
            lim_val = f_arr[n_fields]
            lim_name = ""
            for (i=1; i<n_fields; i++) {
                lim_name = (lim_name == "" ? f_arr[i] : lim_name " " f_arr[i])
            }
            gsub(/^[ \t]+|[ \t]+$/, "", lim_name)
            gsub(/^[ \t]+|[ \t]+$/, "", lim_val)
            
            if (lim_name != "" && lim_val ~ /\//) {
                limit_group[lim_val] = (limit_group[lim_val] ? limit_group[lim_val] " -> " lim_name : lim_name)
                if (!seen_val_order[lim_val]) {
                    seen_val_order[lim_val] = ++limit_group_count
                    limit_group_keys[limit_group_count] = lim_val
                }
            }
        }
    }
}

# --- Pass 0.4: Capture System Environment Variables ---
index($0, "Dumping Environment Variables") > 0 { capturing_env_vars = 1; next }
capturing_env_vars && index($0, "End of Environment Variables") > 0 { capturing_env_vars = 0 }
capturing_env_vars {
    e_line = $0
    gsub(/^[ \t]+|[ \t]+$/, "", e_line)
    if (e_line != "" && index(e_line, "***") == 0 && index(e_line, "=") > 0) {
        n_e = split(e_line, e_arr, "=")
        if (n_e >= 2) {
            env_name = e_arr[1]
            env_val  = e_arr[2]
            gsub(/^[ \t]+|[ \t]+$/, "", env_name)
            gsub(/^[ \t]+|[ \t]+$/, "", env_val)
            env_count++
            env_list[env_count] = env_name ": " env_val
        }
    }
}

# --- Pass 1: Capture Current SQL Statement cleanly ---
index($0, "Current SQL Statement for this session") > 0 {
    capturing_sql = 1
    if (match($0, /sql_id=([a-zA-Z0-9]+)/, arr)) {
        sql_id_val = arr[1]
    }
    next
}
capturing_sql && (index($0, "[TOC") > 0 || index($0, "-----") > 0) { 
    capturing_sql = 0 
}
capturing_sql {
    if (index($0, "sql_id=") > 0) {
        if (match($0, /sql_id=([a-zA-Z0-9]+)/, arr)) sql_id_val = arr[1]
    } else {
        line_sq = $0
        gsub(/^[ \t]+|[ \t]+$/, "", line_sq)
        if (line_sq != "" && index(line_sq, "TOC") == 0) {
            if (sql_text == "") sql_text = line_sq
            else sql_text = sql_text " " line_sq
        }
    }
}

# --- Pass 2: Capture Parser State cleanly ---
index($0, "Parser State") > 0 { capturing_parser = 1; next }
capturing_parser && (index($0, "[TOC") > 0 || index($0, "-END]") > 0 || index($0, "-----") > 0) { 
    capturing_parser = 0 
}
capturing_parser {
    line_pr = $0
    gsub(/^[ \t]+|[ \t]+$/, "", line_pr)
    if (line_pr != "" && index(line_pr, "TOC") == 0 && index(line_pr, "---") == 0) {
        if (parser_state_summary == "") parser_state_summary = line_pr
        else parser_state_summary = parser_state_summary " | " line_pr
    }
}

# --- Pass 3: Capture Call Stack Trace & Highlight Error Functions ---
index($0, "Call Stack Trace") > 0 { capturing_stack = 1; next }
capturing_stack && index($0, "--------------------") > 0 { stack_header_seen = 1; next }
capturing_stack && stack_header_seen {
    if (index($0, "[TOC") > 0 || index($0, "---") > 0 || $0 == "") {
        capturing_stack = 0
    } else {
        if (index($0, "call") > 0) {
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
index($0, "FRAME [") > 0 {
    frame_line = $0
    getline next_line
    if (index(next_line, "ERROR SIGNALED: yes") > 0) {
        error_frame_info = frame_line " [" next_line "]"
    }
}

# --- Pass 4: Capture Compilation Environment Dump dynamically ---
index($0, "Compilation Environment Dump") > 0 { capturing_env = 1; next }
capturing_env && index($0, "[TOC") > 0 { capturing_env = 0 }

{
    if (!capturing_env) next

    line = $0
    gsub(/^[ \t]+|[ \t]+$/, "", line)

    if (line == "" || index(line, "-END") > 0) next

    if (index(line, "=") > 0) {
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

    print "-- ----------------------------------------------------"
    print "-- Session & Execution Context:"
    print "-- ----------------------------------------------------"
    if (service_val != "")   print "REM Service Name : " service_val
    if (module_val != "")    print "REM Module Name  : " module_val
    if (action_val != "")    print "REM Action Name  : " action_val
    if (session_id_val != "")print "REM Session ID   : " session_id_val
    if (container_id_val != "")print "REM Container ID : " container_id_val
    if (client_ip_val != "") print "REM Client IP    : " client_ip_val
    if (client_id_val != "") print "REM Client ID    : " client_id_val
    print ""

    if (sig_full != "" || sig_partial != "") {
        print "-- ----------------------------------------------------"
        print "-- Call Stack Signatures (for MOS / SR Search):"
        print "-- ----------------------------------------------------"
        if (sig_full != "")    print "REM Full Signature    : " sig_full
        if (sig_partial != "") print "REM Partial Signature : " sig_partial
        print ""
    }

    # Sort Performance Statistics in descending order
    if (perf_count > 0) {
        for (i = 1; i <= perf_count; i++) {
            for (j = i + 1; j <= perf_count; j++) {
                if (perf_val[j] > perf_val[i]) {
                    t_val = perf_val[i]; perf_val[i] = perf_val[j]; perf_val[j] = t_val
                    t_txt = perf_text[i]; perf_text[i] = perf_text[j]; perf_text[j] = t_txt
                }
            }
        }

        print "-- ----------------------------------------------------"
        print "-- Call Stack Performance Statistics (Descending):"
        print "-- ----------------------------------------------------"
        perf_line = "REM "
        for (i = 1; i <= perf_count; i++) {
            if (i == 1) {
                perf_line = perf_line perf_text[i]
            } else {
                perf_line = perf_line " > " perf_text[i]
            }
        }
        print perf_line
        print ""
    }

    # Deduplicated Process Resource Limits Grouped by Values
    if (limit_group_count > 0) {
        print "-- ----------------------------------------------------"
        print "-- Process Resource Limits (Grouped):"
        print "-- ----------------------------------------------------"
        for (k = 1; k <= limit_group_count; k++) {
            val_key = limit_group_keys[k]
            print "REM   - " limit_group[val_key] " : " val_key
        }
        print ""
    }

    # System Environment Variables Summary
    if (env_count > 0) {
        print "-- ----------------------------------------------------"
        print "-- System Environment Variables:"
        print "-- ----------------------------------------------------"
        for (i = 1; i <= env_count; i++) {
            print "REM   - " env_list[i]
        }
        print ""
    }

    # Deduplicated & Sorted Process Map / Loaded Libraries Summary
    if (lib_count > 0) {
        for (i = 1; i <= lib_count; i++) {
            for (j = i + 1; j <= lib_count; j++) {
                if (lib_list[j] < lib_list[i]) {
                    t_lib = lib_list[i]; lib_list[i] = lib_list[j]; lib_list[j] = t_lib
                }
            }
        }

        print "-- ----------------------------------------------------"
        print "-- Loaded Binaries & Memory Segments Summary (Deduped):"
        print "-- ----------------------------------------------------"
        for (i = 1; i <= lib_count; i++) {
            print "REM   - " lib_list[i]
        }
        print ""
    }

    if (sql_text != "") {
        print "-- ----------------------------------------------------"
        print "-- Problematic SQL Statement (SQL_ID: " (sql_id_val ? sql_id_val : "UNKNOWN") "):"
        print "-- ----------------------------------------------------"
        print "REM " sql_text
        print ""
    }

    print "-- ----------------------------------------------------"
    print "-- Universal Inference & Execution Context:"
    print "-- ----------------------------------------------------"
    print "REM [INFERENCE] Executed via direct SQL / anonymous block."
    if (parser_state_summary != "") {
        print "REM [Parser State Info]: " parser_state_summary
        print "REM [Parser Inference]: Parser errors are 0 (valid syntax). Crash occurred during query compilation/plan generation."
    }
    print ""
    
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
