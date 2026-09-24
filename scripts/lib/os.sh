#!/usr/bin/env bash
# os.sh — shared OS-detection + portability helpers. Source, don't execute.

case "$(uname -s)" in
    Darwin) ORCHESTRA_OS="darwin" ;;
    Linux)  ORCHESTRA_OS="linux"  ;;
    *)      ORCHESTRA_OS="unknown" ;;
esac

orchestra_venv_dir() {
    if [ "$ORCHESTRA_OS" = "darwin" ]; then printf '%s' "${HOME}/.python-3.12"
    else printf '%s' "${HOME}/Gin-AI/.Gin-AI-python-3.12"; fi
}

orchestra_pid_comm() {  # $1 = pid
    if [ "$ORCHESTRA_OS" = "darwin" ]; then ps -p "$1" -o comm= 2>/dev/null
    else cat "/proc/$1/comm" 2>/dev/null; fi
}

orchestra_pid_ppid() {  # $1 = pid
    if [ "$ORCHESTRA_OS" = "darwin" ]; then ps -p "$1" -o ppid= 2>/dev/null | tr -d '[:space:]'
    else awk '{print $4}' "/proc/$1/stat" 2>/dev/null; fi
}

# Parse "YYYY-MM-DDTHH:MM:SSZ" -> epoch seconds.
orchestra_epoch_from_iso() {
    if [ "$ORCHESTRA_OS" = "darwin" ]; then date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null
    else date -d "$1" +%s 2>/dev/null; fi
}

# Parse "YYYY-MM-DD" -> epoch seconds at UTC midnight.
# NOTE: BSD `date -j -f "%Y-%m-%d"` fills missing H:M:S with the CURRENT
# wall-clock time, not midnight (verified live) — append a fixed T00:00:00Z.
orchestra_epoch_from_ymd() {
    if [ "$ORCHESTRA_OS" = "darwin" ]; then date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "${1}T00:00:00Z" +%s 2>/dev/null
    else date -d "$1" +%s 2>/dev/null; fi
}
