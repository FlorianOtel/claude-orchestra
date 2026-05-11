#!/usr/bin/env bash
# ctx-segment.sh — emit the ctx status-line segment
# Usage: ctx-segment.sh <used_percentage> <tokens_used> <context_window_size> <model_id>
# Output: colored segment (e.g., "ctx ▓▓░░░░░░ 12% 24K/200K") or nothing on error

set -euo pipefail

# Validate args
if [ $# -lt 4 ]; then
    exit 0
fi

used_pct="$1"
tokens="$2"
cc_context_size="$3"
model_id="$4"

# Validate numeric args
if ! [[ "$used_pct" =~ ^[0-9]+$ ]] || ! [[ "$tokens" =~ ^[0-9]+$ ]] || ! [[ "$cc_context_size" =~ ^[0-9]+$ ]]; then
    exit 0
fi

# [1m]-aware normalisation
# If original model_id contains [1m], force 1000000 denominator
original_id="$model_id"
if [[ "$original_id" == *"[1m]"* ]]; then
    forced_1m=true
else
    forced_1m=false
fi

# Strip [1m], [200k], -YYYYMMDD etc. for lookup
normalised_id=$(echo "$model_id" | sed -E 's/\[.*\]$//' | sed -E 's/-[0-9]{8}$//')

# If normalised is empty, use original for fallback
if [ -z "$normalised_id" ]; then
    normalised_id="$model_id"
fi

# Lookup in YAML (fallback to CC size if missing/not found)
yaml_file="$HOME/.claude/orchestra/context-windows.yaml"
if [ -f "$yaml_file" ]; then
    advertised_size=$("${HOME}/Gin-AI/.Gin-AI-python-3.12/bin/python3" -c "
import sys, yaml
model = '$normalised_id'.lower()
yaml_path = '$yaml_file'
try:
    with open(yaml_path, 'r') as f:
        cfg = yaml.safe_load(f)
    models = cfg.get('models', {})
    # Direct lookup
    if model in models:
        print(models[model])
    else:
        # Fallback: display_name normalisation (lowercase, hyphenate, strip parentheticals)
        fallback = model.replace(' ', '-').split('(')[0].strip('-')
        if fallback in models:
            print(models[fallback])
        else:
            print("")
except Exception:
    print("")
" 2>/dev/null || true)
else
    advertised_size=""
fi

# Fall back to CC context_window_size if no YAML or no match
if [ -z "$advertised_size" ]; then
    advertised_size="$cc_context_size"
fi

# Special case: [1m] force 1000000
if [ "$forced_1m" = true ]; then
    advertised_size=1000000
fi

# Format tokens (K or M)
format_tokens() {
    local t="$1"
    if [ "$t" -ge 1000000 ]; then
        # M format with one decimal, no trailing .0 for exact millions
        local val=$(awk "BEGIN {printf \"%.1f\", $t/1000000}")
        # For display, we want "1.0M" or "1.2M"
        # Check if it's a whole number (no decimal part)
        local integer_part=$(echo "$val" | cut -d. -f1)
        if [ "$val" = "$integer_part.0" ]; then
            echo "${integer_part}M"
        else
            echo "${val}M"
        fi
    elif [ "$t" -ge 1000 ]; then
        echo "$((t / 1000))K"
    else
        echo "${t}K"
    fi
}

used_fmt=$(format_tokens "$tokens")
total_fmt=$(format_tokens "$advertised_size")

# Build 10-cell bar (floor: 10% = 1 cell)
filled=$(awk "BEGIN {print int($used_pct / 10)}")

# Clamp to 0-10
if [ "$filled" -lt 0 ]; then filled=0; fi
if [ "$filled" -gt 10 ]; then filled=10; fi

bar=""
for ((i=0; i<filled; i++)); do
    bar+="▓"
done
for ((i=filled; i<10; i++)); do
    bar+="░"
done

# Color by threshold
# Gruvbox Aqua:  (142, 192, 124) - used < 50
# Gruvbox Yellow: (224, 175, 104) - used < 80
# Gruvbox Orange: (254, 128, 25)  - used >= 80
if [ "$used_pct" -lt 50 ]; then
    color="\033[38;2;142;192;124m"
    fg="142;192;124"
elif [ "$used_pct" -lt 80 ]; then
    color="\033[38;2;224;175;104m"
    fg="224;175;104"
else
    color="\033[38;2;254;128;25m"
    fg="254;128;25"
fi

reset="\033[0m"

# Output format: "ctx ▓▓░░░░░░░░ 12% 120K/1M" with color
printf "%sctx %s %d%% %s/%s%s" "$color" "$bar" "$used_pct" "$used_fmt" "$total_fmt" "$reset"
