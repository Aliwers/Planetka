#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="/Applications/Planetka.app"
AGENT_LABEL="com.local.planetka.agent"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/planetka-local-install.XXXXXX")"
STAGED_APP="$WORK_DIR/Planetka.app"
INCOMING="/Applications/.Planetka.incoming.$$"
BACKUP="/Applications/.Planetka.previous.$$"

cleanup() {
    rm -rf "$WORK_DIR" "$INCOMING"
}
trap cleanup EXIT

identity="${PLANETKA_SIGN_IDENTITY:-}"
if [[ -z "$identity" && -d "$APP_PATH" ]]; then
    identity="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1 \
        | sed -n 's/^Authority=\(Apple Development:.*\)$/\1/p' \
        | head -n 1)"
fi
if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' \
        | head -n 1)"
fi
if [[ -z "$identity" ]]; then
    printf 'Planetka: no Apple Development signing identity was found.\n' >&2
    printf 'Set PLANETKA_SIGN_IDENTITY explicitly; ad-hoc local installs are disabled because they reset macOS permissions.\n' >&2
    exit 1
fi

SIGN_IDENTITY="$identity" "$ROOT_DIR/scripts/build-app.sh" "$STAGED_APP"

codesign --verify --deep --strict "$STAGED_APP"
identifier="$(codesign -d --verbose=4 "$STAGED_APP" 2>&1 \
    | sed -n 's/^Identifier=//p')"
[[ "$identifier" == "com.local.planetka" ]] || {
    printf 'Planetka: unexpected bundle identifier: %s\n' "$identifier" >&2
    exit 1
}
if [[ -d "$APP_PATH" ]]; then
    installed_requirement="$(codesign -d -r- "$APP_PATH" 2>&1 | tail -n 1)"
    staged_requirement="$(codesign -d -r- "$STAGED_APP" 2>&1 | tail -n 1)"
    [[ "$installed_requirement" == "$staged_requirement" ]] || {
        printf 'Planetka: refusing to change the installed signing identity because that would reset macOS permissions.\n' >&2
        exit 1
    }
fi

uid="$(id -u)"
launchctl bootout "gui/$uid/$AGENT_LABEL" >/dev/null 2>&1 || true
pkill -f '/Applications/Planetka.app/Contents/MacOS/Planetka' >/dev/null 2>&1 || true

ditto "$STAGED_APP" "$INCOMING"
codesign --verify --deep --strict "$INCOMING"

if [[ -e "$APP_PATH" ]]; then
    mv "$APP_PATH" "$BACKUP"
fi
if ! mv "$INCOMING" "$APP_PATH"; then
    if [[ -e "$BACKUP" ]]; then
        mv "$BACKUP" "$APP_PATH"
    fi
    exit 1
fi
rm -rf "$BACKUP"

# A plist left by an earlier bundle keeps launchd pinned to that path, and
# bootstrap refuses to replace a loaded service, so repoint it first.
if [[ -f "$AGENT_PLIST" ]]; then
    /usr/libexec/PlistBuddy -c \
        "Set :ProgramArguments:0 $APP_PATH/Contents/MacOS/Planetka" \
        "$AGENT_PLIST" >/dev/null
    launchctl bootstrap "gui/$uid" "$AGENT_PLIST" >/dev/null 2>&1 || true
    launchctl kickstart -k "gui/$uid/$AGENT_LABEL"
    printf 'Planetka: restarted the background agent.\n'
else
    printf 'Planetka: start the dictation service once from the app to register the agent.\n'
fi

printf 'Planetka: installed one signed app at %s.\n' "$APP_PATH"
