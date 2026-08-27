#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGDIR="${LAUNCHER_LOG_DIR:-$SCRIPT_DIR/logs}"
mkdir -p "$LOGDIR"

# Find iperf3 explicitly: GUI-launched scripts don't get Homebrew's PATH
IPERF3="$(command -v iperf3 || true)"
if [ -z "$IPERF3" ]; then
    for p in /opt/homebrew/bin/iperf3 /usr/local/bin/iperf3; do
        [ -x "$p" ] && IPERF3="$p" && break
    done
fi
if [ -z "$IPERF3" ]; then
    echo "ERROR: iperf3 not found (checked PATH, /opt/homebrew/bin, /usr/local/bin)" \
        > "$LOGDIR/iperf3-server.log"
    exit 1
fi

LOGFILE="$LOGDIR/iperf3-server.log"

# Skip if a server is already running (avoid clobbering its log)
if pgrep -x iperf3 >/dev/null; then
    echo "$(date '+%Y-%m-%d %H:%M:%S')  iperf3 already running (PID $(pgrep -x iperf3 | head -1)); leaving it as is." >> "$LOGFILE"
    exit 0
fi

{
    echo "===== iperf3 server started $(date '+%Y-%m-%d %H:%M:%S') ====="
    echo "Binary: $IPERF3 ($("$IPERF3" --version | head -1))"
    echo "Listening on port 5201 (TCP and UDP)..."
} > "$LOGFILE"

nohup "$IPERF3" -s >> "$LOGFILE" 2>&1 &
echo "Launched iperf3 server (PID $!)." >> "$LOGFILE"
exit 0