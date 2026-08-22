#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

bash -n install.sh uninstall.sh scripts/build-app.sh scripts/check.sh
plutil -lint swift/Info.plist entitlements.plist

app_version="$(plutil -extract CFBundleShortVersionString raw -o - swift/Info.plist)"
installer_version="$(sed -n 's/^RELEASE_VERSION="\([^"]*\)"$/\1/p' install.sh)"
installer_sha256="$(sed -n 's/^RELEASE_SHA256="\([^"]*\)"$/\1/p' install.sh)"
manifest_version="$(plutil -extract version raw -o - update.json)"
manifest_sha256="$(plutil -extract sha256 raw -o - update.json)"
[[ -n "$installer_version" && "$app_version" == "$installer_version" ]] || {
    printf 'Version mismatch: Info.plist=%s install.sh=%s\n' "$app_version" "$installer_version" >&2
    exit 1
}
[[ "$manifest_version" == "$app_version" ]] || {
    printf 'Version mismatch: Info.plist=%s update.json=%s\n' "$app_version" "$manifest_version" >&2
    exit 1
}
[[ "$manifest_sha256" == "$installer_sha256" && "$manifest_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    printf 'Checksum mismatch: install.sh=%s update.json=%s\n' "$installer_sha256" "$manifest_sha256" >&2
    exit 1
}

grep -q 'com.apple.security.device.audio-input' entitlements.plist
grep -q 'com.apple.security.device.microphone' entitlements.plist

# `! grep` is exempt from `set -e`, so a negative check has to fail by hand or
# it silently passes forever.
if grep -q 'raw.githubusercontent.com/Aliwers/Planetka/main/' README.md; then
    printf 'README pins an install command to /main/ instead of /v%s/.\n' "$app_version" >&2
    exit 1
fi
grep -q 'raw.githubusercontent.com/Aliwers/Planetka/v'"$app_version"'/' README.md
grep -q '^REF="${PLANETKA_REF:-\$SOURCE_COMMIT}"$' install.sh
grep -q '^EXPECTED_SOURCE_COMMIT="${PLANETKA_SOURCE_COMMIT:-\$SOURCE_COMMIT}"$' install.sh
grep -q 'verify_source_ref' install.sh
grep -q 'sysctl.proc_translated' install.sh
grep -q 'is_apple_silicon' install.sh
grep -q 'Restarting the build natively for Apple Silicon' scripts/build-app.sh
grep -q 'validate_output_app_path "$OUTPUT_APP"' scripts/build-app.sh

# The smoke test must read the expected version from the manifest; a literal
# there silently rots one release after it is written.
if grep -qE 'CFBundleShortVersionString.*= "[0-9]' .github/workflows/release-smoke.yml; then
    printf 'release-smoke.yml hardcodes a version; read it from update.json instead.\n' >&2
    exit 1
fi

git diff --check
printf 'Planetka checks passed (v%s).\n' "$app_version"
