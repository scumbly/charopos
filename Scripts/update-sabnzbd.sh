#!/bin/bash
# update-sabnzbd.sh — Check for and install SABnzbd updates on macOS
# Usage: ./update-sabnzbd.sh [--check]
#   --check : print "update available: X.X.X" if a newer version exists, then exit.
#             No log file is written in --check mode.
# Env vars (set by Charopos launcher):
#   SAB_API_KEY      — SABnzbd API key
#   SAB_URL          — SABnzbd base URL (derived from the configured health URL)
#   LAUNCHER_LOG_DIR — directory for UpdateSAB_*.log files

set -euo pipefail

# Honor the URL Charopos injects; fall back to SABnzbd's stock port for
# standalone runs. (An unconditional assignment here used to override the
# injected value with a hardcoded personal port.)
SAB_URL="${SAB_URL:-http://127.0.0.1:8080}"
GITHUB_API="https://api.github.com/repos/sabnzbd/sabnzbd/releases/latest"
CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

if [[ -z "${SAB_API_KEY:-}" ]]; then
  echo "ERROR: SAB_API_KEY not set"
  exit 1
fi

# --- Fetch current version from running SABnzbd -------------------------
get_current_version() {
  python3 - <<'PY' 2>/dev/null
import urllib.request, json, sys
try:
    import os
    url = os.environ['SAB_URL'] + '/api?mode=version&output=json&apikey=' + os.environ['SAB_API_KEY']
    r = urllib.request.urlopen(url, timeout=5)
    print(json.loads(r.read())['version'])
except Exception as e:
    sys.exit(1)
PY
}

# --- Fetch latest release info from GitHub ------------------------------
get_latest_info() {
  python3 - <<'PY' 2>/dev/null
import urllib.request, json, sys
try:
    req = urllib.request.Request(
        'https://api.github.com/repos/sabnzbd/sabnzbd/releases/latest',
        headers={'User-Agent': 'Charopos/1.0', 'Accept': 'application/vnd.github+json'}
    )
    r = urllib.request.urlopen(req, timeout=10)
    d = json.loads(r.read())
    tag = d['tag_name'].lstrip('v')
    # SABnzbd renamed the macOS asset from "-macOS.dmg" to "-macos.dmg" in 5.1.0;
    # match case-insensitively so either naming works.
    assets = [a for a in d.get('assets', []) if a['name'].lower().endswith('-macos.dmg')]
    dmg_url = assets[0]['browser_download_url'] if assets else ''
    print(tag + '|' + dmg_url)
except Exception:
    sys.exit(1)
PY
}

# Returns 0 (true) if $1 is strictly newer than $2 using sort -V
newer() {
  [[ "$1" != "$2" ]] && [[ "$1" = "$(printf '%s\n' "$1" "$2" | sort -V | tail -1)" ]]
}

# Export for python3 heredocs
export SAB_URL SAB_API_KEY

CURRENT=$(get_current_version) || { echo "ERROR: Cannot reach SABnzbd API at $SAB_URL"; exit 1; }
LATEST_INFO=$(get_latest_info)  || { echo "ERROR: Cannot fetch GitHub release info";       exit 1; }
LATEST="${LATEST_INFO%%|*}"
DMG_URL="${LATEST_INFO##*|}"

# ---- Check-only mode ---------------------------------------------------
if [[ $CHECK_ONLY -eq 1 ]]; then
  if newer "$LATEST" "$CURRENT"; then
    echo "update available: $LATEST (installed: $CURRENT)"
  fi
  exit 0
fi

# ---- Full update -------------------------------------------------------

LOG_DIR="${LAUNCHER_LOG_DIR:-/tmp}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/UpdateSAB_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== SABnzbd Update — $(date) ==="
echo "Installed: $CURRENT"
echo "Latest:    $LATEST"

if ! newer "$LATEST" "$CURRENT"; then
  echo "SABnzbd is already up to date ($CURRENT)."
  exit 0
fi

if [[ -z "$DMG_URL" ]]; then
  echo "ERROR: No macOS DMG found in latest GitHub release"
  exit 1
fi

# Find SABnzbd.app (installed as a standard .app)
SAB_APP=$(find /Applications ~/Applications -maxdepth 2 -name "SABnzbd.app" -type d 2>/dev/null | head -1 || true)
if [[ -z "$SAB_APP" ]]; then
  echo "ERROR: SABnzbd.app not found in /Applications or ~/Applications"
  exit 1
fi
SAB_DIR=$(dirname "$SAB_APP")
echo "Found: $SAB_APP"

# Pause queue so in-progress downloads don't corrupt mid-install
echo "Pausing SABnzbd queue..."
python3 -c "
import urllib.request, os
urllib.request.urlopen(
    os.environ['SAB_URL'] + '/api?mode=pause&apikey=' + os.environ['SAB_API_KEY'],
    timeout=5
)
print('Queue paused.')
" 2>/dev/null || echo "(could not pause queue — continuing)"

# Quit SABnzbd
echo "Quitting SABnzbd..."
pkill -TERM -x "SABnzbd" 2>/dev/null || true
for _ in $(seq 1 20); do
  pgrep -x "SABnzbd" >/dev/null 2>&1 || break
  sleep 1
done
pkill -KILL -x "SABnzbd" 2>/dev/null || true
sleep 1

# Download DMG
TMP_DMG=$(mktemp /tmp/SABnzbd-XXXXXX.dmg)
echo "Downloading: $DMG_URL"
curl -fL -o "$TMP_DMG" "$DMG_URL"
echo "Download complete."

# Mount, install, unmount
MOUNT_PT=$(mktemp -d /tmp/sabnzbd-mount-XXXXXX)
echo "Mounting DMG..."
hdiutil attach "$TMP_DMG" -mountpoint "$MOUNT_PT" -nobrowse -quiet

APP_IN_DMG=$(find "$MOUNT_PT" -maxdepth 1 -name "SABnzbd*.app" -type d 2>/dev/null | head -1 || true)
if [[ -z "$APP_IN_DMG" ]]; then
  echo "ERROR: SABnzbd.app not found inside DMG"
  hdiutil detach "$MOUNT_PT" -quiet 2>/dev/null || true
  rm -f "$TMP_DMG"; rm -rf "$MOUNT_PT"
  exit 1
fi

SAB_BACKUP="${SAB_APP}.bak"
[[ -e "$SAB_BACKUP" ]] && { echo "Removing previous backup..."; rm -rf "$SAB_BACKUP"; }
echo "Backing up old bundle..."
mv "$SAB_APP" "$SAB_BACKUP"

echo "Installing to $SAB_DIR ..."
if ! ditto "$APP_IN_DMG" "$SAB_DIR/SABnzbd.app"; then
  echo "Install failed — restoring backup."
  rm -rf "$SAB_DIR/SABnzbd.app" 2>/dev/null || true
  mv "$SAB_BACKUP" "$SAB_APP"
  hdiutil detach "$MOUNT_PT" -quiet 2>/dev/null || true
  rm -f "$TMP_DMG"; rm -rf "$MOUNT_PT"
  exit 1
fi
echo "Installed."

echo "Removing quarantine and signing..."
xattr -rd com.apple.quarantine "$SAB_DIR/SABnzbd.app" 2>/dev/null || true
codesign --force --sign - "$SAB_DIR/SABnzbd.app"

hdiutil detach "$MOUNT_PT" -quiet
rm -f "$TMP_DMG"
rm -rf "$MOUNT_PT"
echo "SABnzbd updated to $LATEST."

# Relaunch. Open by full path, not by name: the bundle was just replaced and
# re-signed, so Launch Services may not have re-indexed it yet and `open -a
# SABnzbd` fails with "Unable to find application named 'SABnzbd'".
echo "Relaunching SABnzbd..."
open "$SAB_DIR/SABnzbd.app"
echo "Done. SABnzbd $LATEST is running."
