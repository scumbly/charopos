#!/usr/bin/env bash
#
# update-arr.sh -- Update Radarr/Sonarr/Lidarr/Prowlarr on macOS,
# working around Gatekeeper.
#
# What it does, per app:
#   1. Reads the installed version from the .app's Info.plist
#   2. Asks the GitHub releases API for the latest release
#   3. If newer, downloads the correct osx (arm64/x64) .app.zip asset
#   4. Quits the app, backs up the old bundle, swaps in the new one
#   5. Strips the com.apple.quarantine attribute and ad-hoc codesigns
#      (the officially documented Servarr workaround)
#   6. Relaunches the app
#
# Your config/database is untouched -- it lives in ~/.config/<App>,
# not inside the .app bundle.
#
# Usage:
#   ./update-arr.sh                  # update all four (skips any not installed)
#   ./update-arr.sh Radarr           # just one
#   ./update-arr.sh --check          # report versions only, change nothing
#   ./update-arr.sh --prerelease     # track develop/pre-release builds
#                                    # (match this to the Branch setting in
#                                    #  each app: main/master = stable,
#                                    #  develop = prerelease)
#
# Requirements: macOS, curl, python3 (ships with macOS) for JSON parsing.

set -euo pipefail

APPS_DEFAULT=("Radarr" "Sonarr" "Lidarr" "Prowlarr")
APP_DIR="/Applications"
CHECK_ONLY=false
PRERELEASE=false

# ---------------------------------------------------------------- helpers

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '\033[1;31m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

github_repo() {
  case "$1" in
    Radarr)   echo "Radarr/Radarr" ;;
    Sonarr)   echo "Sonarr/Sonarr" ;;
    Lidarr)   echo "Lidarr/Lidarr" ;;
    Prowlarr) echo "Prowlarr/Prowlarr" ;;
    *) die "Unknown app: $1 (supported: Radarr, Sonarr, Lidarr, Prowlarr)" ;;
  esac
}

arch_tag() {
  case "$(uname -m)" in
    arm64)  echo "arm64" ;;
    x86_64) echo "x64" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

STATE_DIR="$HOME/.config/arr-update"

installed_version() {
  local app="$1" plist="$APP_DIR/$1.app/Contents/Info.plist" v=""
  if [[ ! -f "$plist" ]]; then
    echo "not-installed"
    return
  fi
  v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null \
      || true)
  # Some apps (Sonarr) only put the major version (e.g. "4.0") in the plist,
  # which would make every release look like an update. Fall back to the
  # marker this script writes after each successful update.
  if [[ ! "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && -f "$STATE_DIR/$app.version" ]]; then
    v=$(cat "$STATE_DIR/$app.version")
  fi
  echo "${v:-unknown}"
}

# Returns "tag_name<TAB>download_url" for the matching osx app.zip asset.
# Stable channel uses /releases/latest; --prerelease scans the full release
# list (newest first) and takes the first one with a matching asset.
latest_release() {
  local repo="$1" arch="$2" endpoint
  if $PRERELEASE; then
    endpoint="https://api.github.com/repos/$repo/releases?per_page=15"
  else
    endpoint="https://api.github.com/repos/$repo/releases/latest"
  fi
  curl -fsSL --max-time 15 "$endpoint" | python3 -c "
import json, sys
arch = '$arch'
data = json.load(sys.stdin)
releases = data if isinstance(data, list) else [data]
def find_asset(rel):
    for a in rel.get('assets', []):
        n = a['name'].lower()
        # Matches both naming schemes:
        #   Radarr/Sonarr:    *.osx-arm64.app.zip
        #   Lidarr/Prowlarr:  *.osx-app-core-arm64.zip
        if 'osx' in n and arch in n and 'app' in n and n.endswith('.zip'):
            return a['browser_download_url']
    return ''
for r in releases:
    if r.get('draft'):
        continue
    url = find_asset(r)
    if url:
        print(r['tag_name'].lstrip('v') + '\t' + url)
        break
else:
    print('\t')
"
}

quit_app() {
  local app="$1"
  if pgrep -x "$app" >/dev/null 2>&1; then
    log "Stopping $app (SIGTERM)..."
    # Don't use osascript here: the *arr apps are headless and never reply
    # to the quit Apple Event, so osascript blocks forever. SIGTERM triggers
    # a clean .NET shutdown instead.
    pkill -TERM -x "$app" || true
    # Give it up to 20s to exit cleanly, then force it
    for _ in $(seq 1 20); do
      pgrep -x "$app" >/dev/null 2>&1 || return 0
      sleep 1
    done
    warn "$app didn't exit after SIGTERM; force-killing."
    pkill -KILL -x "$app" || true
    sleep 2
  fi
}

# ---------------------------------------------------------------- main

APPS=()
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=true ;;
    --prerelease) PRERELEASE=true ;;
    *) APPS+=("$arg") ;;
  esac
done
[[ ${#APPS[@]} -eq 0 ]] && APPS=("${APPS_DEFAULT[@]}")

ARCH=$(arch_tag)

# Signing identity: prefer a stable self-signed certificate so macOS TCC
# permission grants (e.g. network volume access) survive updates. Ad-hoc
# signing ("-") creates a new identity every time, which makes macOS
# re-prompt for permissions after each update.
# Create the cert once in Keychain Access (see notes), name it: arr-selfsign
SIGN_IDENTITY="${ARR_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "arr-selfsign"; then
    SIGN_IDENTITY="arr-selfsign"
  else
    SIGN_IDENTITY="-"
    warn "No valid 'arr-selfsign' certificate found; using ad-hoc signing."
    warn "Note: macOS will re-prompt for folder/network permissions after each update."
    warn "If you created the cert, it must also be set to 'Always Trust' for"
    warn "Code Signing (Keychain Access > double-click cert > Trust)."
  fi
fi
log "Code signing identity: $SIGN_IDENTITY"

TMPROOT=$(mktemp -d /tmp/arr-update.XXXXXX)
trap 'rm -rf "$TMPROOT" 2>/dev/null || true' EXIT

for APP in "${APPS[@]}"; do
  REPO=$(github_repo "$APP")
  CURRENT=$(installed_version "$APP")

  if [[ "$CURRENT" == "not-installed" ]]; then
    warn "$APP.app not found in $APP_DIR -- skipping."
    continue
  fi

  log "$APP installed: $CURRENT -- checking $REPO..."
  IFS=$'\t' read -r LATEST URL < <(latest_release "$REPO" "$ARCH")

  if [[ -z "$URL" ]]; then
    warn "No osx-$ARCH app.zip asset found in the latest $APP release -- skipping."
    continue
  fi

  if [[ "$CURRENT" == "$LATEST" ]]; then
    log "$APP is already up to date ($CURRENT)."
    continue
  fi

  log "$APP update available: $CURRENT -> $LATEST"
  if $CHECK_ONLY; then
    continue
  fi

  WORK="$TMPROOT/$APP"
  mkdir -p "$WORK"
  ZIP="$WORK/$APP.app.zip"

  log "Downloading $URL"
  curl -fL -o "$ZIP" "$URL"

  log "Extracting..."
  ditto -x -k "$ZIP" "$WORK/extracted"
  NEW_APP=$(find "$WORK/extracted" -maxdepth 2 -name "$APP.app" -type d | head -n1)
  [[ -d "$NEW_APP" ]] || { warn "Couldn't find $APP.app inside the archive -- skipping."; continue; }

  quit_app "$APP"

  BACKUP="$APP_DIR/$APP.app.bak"
  if [[ -e "$BACKUP" ]]; then
    log "Removing previous backup..."
    chflags -R nouchg,noschg "$BACKUP" 2>/dev/null || true
    if ! rm -rf "$BACKUP" 2>/dev/null; then
      # macOS rm can fail on app bundles (locked files, xattr races).
      # Move it aside instead of aborting; it gets cleaned up with TMPROOT.
      warn "Couldn't delete old backup; moving it aside."
      mv "$BACKUP" "$TMPROOT/$APP.app.bak.old" \
        || { warn "Couldn't clear $BACKUP -- skipping $APP. Remove it manually."; continue; }
    fi
  fi
  log "Backing up old bundle to $BACKUP"
  mv "$APP_DIR/$APP.app" "$BACKUP"

  log "Installing new bundle..."
  if ! ditto "$NEW_APP" "$APP_DIR/$APP.app"; then
    warn "Install failed -- restoring backup."
    rm -rf "$APP_DIR/$APP.app"
    mv "$BACKUP" "$APP_DIR/$APP.app"
    continue
  fi

  log "Removing quarantine attribute and signing (identity: $SIGN_IDENTITY)..."
  xattr -rd com.apple.quarantine "$APP_DIR/$APP.app" 2>/dev/null || true
  codesign --force --deep -s "$SIGN_IDENTITY" "$APP_DIR/$APP.app"

  log "Relaunching $APP..."
  open "$APP_DIR/$APP.app"

  # Record the installed version (used for apps whose plist lacks it)
  mkdir -p "$STATE_DIR"
  echo "$LATEST" > "$STATE_DIR/$APP.version"

  # Keep the backup until next run in case something is off;
  # uncomment the next line to delete it immediately instead.
  # rm -rf "$BACKUP"

  log "$APP updated to $LATEST OK"
done

log "Done."