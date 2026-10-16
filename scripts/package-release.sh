#!/bin/bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ./scripts/package-release.sh [--arch arm64|x86_64]

Build release ZIPs for Apple Silicon and Intel, or only the specified architecture.
The version comes from Resources/Info.plist. Outputs go to build/release by default.
Set CALENDAR_SYNC_RELEASE_DIR to an absolute path to choose another output folder.
Each archive is extracted and checked for its code signature and architecture.
The apps are ad-hoc signed previews, not Developer ID signed or notarized.
This command does not install, launch, or publish the app, or access calendars.
USAGE
}

architectures=(arm64 x86_64)
while [ "$#" -gt 0 ]; do
    case "$1" in
        --arch)
            if [ "$#" -lt 2 ]; then usage >&2; exit 2; fi
            case "$2" in
                arm64|x86_64) architectures=("$2") ;;
                *) usage >&2; exit 2 ;;
            esac
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

if [ "$(uname -s)" != "Darwin" ]; then
    printf '%s\n' 'Calendar Sync must be packaged on macOS with the Xcode command-line tools.' >&2
    exit 1
fi

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_directory="${CALENDAR_SYNC_RELEASE_DIR:-$project_root/build/release}"
case "$output_directory" in
    /*) ;;
    *) printf '%s\n' 'CALENDAR_SYNC_RELEASE_DIR must be an absolute path.' >&2; exit 2 ;;
esac
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_root/Resources/Info.plist")"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Expected a three-part numeric release version, found: %s\n' "$version" >&2
    exit 1
fi

# Keep all .app bundles outside synced workspaces. Archive only the generated app:
# no Calendar data, local settings, source checkout, or developer credentials.
staging_directory="$(mktemp -d "${TMPDIR:-/tmp}/calendar-sync-release.XXXXXX")"
trap 'rm -rf "$staging_directory"' EXIT
archive_names=()
for architecture in "${architectures[@]}"; do
    bundle_directory="$staging_directory/$architecture"
    CALENDAR_SYNC_BUILD_DIR="$bundle_directory" \
        "$project_root/scripts/build-app.sh" release --arch "$architecture"
    archive_name="Calendar-Sync-v${version}-macos-${architecture}.zip"
    archive_path="$staging_directory/$archive_name"
    ditto -c -k --norsrc --noextattr --keepParent \
        "$bundle_directory/Calendar Sync.app" "$archive_path"

    verification_directory="$staging_directory/verify-$architecture"
    ditto -x -k "$archive_path" "$verification_directory"
    verified_app="$verification_directory/Calendar Sync.app"
    codesign --verify --strict --verbose=2 "$verified_app"
    plutil -lint "$verified_app/Contents/Info.plist"
    actual_architecture="$(xcrun lipo -archs "$verified_app/Contents/MacOS/CalendarSync")"
    if [ "$actual_architecture" != "$architecture" ]; then
        printf 'Archive architecture mismatch: expected %s, found %s.\n' "$architecture" "$actual_architecture" >&2
        exit 1
    fi
    archive_names+=("$archive_name")
done

(
    cd "$staging_directory"
    shasum -a 256 "${archive_names[@]}" > SHA256SUMS
    shasum -a 256 -c SHA256SUMS
)
mkdir -p "$output_directory"
for archive_name in "${archive_names[@]}"; do
    cp "$staging_directory/$archive_name" "$output_directory/$archive_name"
done
cp "$staging_directory/SHA256SUMS" "$output_directory/SHA256SUMS"
printf 'Verified release archives and SHA256SUMS: %s\n' "$output_directory"
printf '%s\n' 'Ad-hoc signed preview; not Developer ID signed or notarized.'
