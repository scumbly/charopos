#!/usr/bin/env bash
#
# Update Arr.command -- double-clickable launcher for update-arr.sh.
# Keep this file in the same folder as update-arr.sh.
#
# macOS opens .command files in Terminal, so you can watch the update log.
# Output is also saved to the logs folder (last 10 runs kept).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Server Launcher.app sets LAUNCHER_LOG_DIR; standalone runs log next to the script
LOGDIR="${LAUNCHER_LOG_DIR:-$SCRIPT_DIR/logs}"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/UpdateArr_$(date +%Y-%m-%d_%H-%M-%S).log"

# Prune old logs, keeping only the 10 newest (including this run's)
ls -1t "$LOGDIR"/UpdateArr_*.log 2>/dev/null | tail -n +10 | while IFS= read -r old; do
  rm -f "$old"
done

if [[ ! -x "$SCRIPT_DIR/update-arr.sh" ]]; then
  echo "Could not find an executable update-arr.sh next to this launcher." | tee "$LOGFILE"
  echo "Expected: $SCRIPT_DIR/update-arr.sh" | tee -a "$LOGFILE"
  read -r -p "Press Return to close."
  exit 1
fi

"$SCRIPT_DIR/update-arr.sh" "$@" 2>&1 | tee "$LOGFILE"
STATUS=${PIPESTATUS[0]}

echo
if [[ $STATUS -eq 0 ]]; then
  read -r -p "All done. Press Return to close this window."
else
  read -r -p "Finished with errors (exit $STATUS). Press Return to close."
fi
exit $STATUS
