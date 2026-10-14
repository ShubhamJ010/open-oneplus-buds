#!/bin/zsh
set -euo pipefail

# audit_perf.sh: Quick diagnostic snapshot of running Buds macOS app
# Usage: ./audit_perf.sh [Buds|PID] [SampleCount]

TARGET="${1:-Buds}"
SAMPLE_COUNT="${2:-3}"

if [[ "$TARGET" =~ ^[0-9]+$ ]]; then
  PID="$TARGET"
  APP_NAME=$(ps -p "$PID" -o comm= 2>/dev/null | xargs basename || echo "$TARGET")
else
  APP_NAME="$TARGET"
  PID=$(pgrep -fl "$APP_NAME" | head -n 1 | awk '{print $1}')
  if [[ -z "$PID" ]]; then
    echo "Error: No running process found matching '$APP_NAME'" >&2
    exit 1
  fi
fi

echo "=================================================="
echo "Performance Audit: $APP_NAME (PID: $PID)"
echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "=================================================="

echo ""
echo "--- Process Details ---"
ps -p "$PID" -o pid,ppid,user,%cpu,%mem,vsz,rss,stat,time,command

echo ""
echo "--- Live Resource Sampling (top $SAMPLE_COUNT samples) ---"
top -l "$SAMPLE_COUNT" -s 1 -pid "$PID" -stats pid,command,cpu,power,csw,threads,mem,idlew | grep -E "PID|COMMAND|$PID" || true

echo ""
echo "--- Memory Footprint (vmmap) ---"
if command -v vmmap >/dev/null 2>&1; then
  vmmap -summary "$PID" 2>/dev/null | grep -E "Physical footprint|TOTAL, minus reserved" || true
fi

echo ""
echo "--- Memory Leaks Check ---"
if command -v leaks >/dev/null 2>&1; then
  leaks "$PID" 2>&1 | grep -E "leaks for|total leaked bytes" || echo "No leaks detected or leaks tool skipped."
fi

echo ""
echo "--- Recent Live Logs (last 1m, tail 15) ---"
/usr/bin/log show --predicate "process == \"$APP_NAME\"" --info --last 1m --style compact 2>/dev/null | tail -n 15 || true

echo "=================================================="
