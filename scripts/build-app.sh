#!/bin/bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ./scripts/build-app.sh [debug|release] [--arch arm64|x86_64]

Build and package Calendar Sync for the current Mac architecture, or --arch.
The default configuration is release. The app is ad-hoc signed for local use.
Set CALENDAR_SYNC_BUILD_DIR to an absolute path for a different output folder.
This command does not launch or install the app, enable login items, or access calendars.
USAGE
}

configuration="release"
architecture="$(uname -m)"
while [ "$#" -gt 0 ]; do
    case "$1" in
        debug|release) configuration="$1"; shift ;;
        --arch)
            if [ "$#" -lt 2 ]; then usage >&2; exit 2; fi
            architecture="$2"
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
case "$architecture" in
    arm64|x86_64) ;;
    *) printf '%s\n' 'Architecture must be arm64 or x86_64.' >&2; exit 2 ;;
esac

if [ "$(uname -s)" != "Darwin" ]; then
    printf '%s\n' 'Calendar Sync must be built on macOS with the Xcode command-line tools.' >&2
    exit 1
fi

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_directory="${CALENDAR_SYNC_BUILD_DIR:-$project_root/build}"
case "$build_directory" in
    /*) ;;
    *) printf '%s\n' 'CALENDAR_SYNC_BUILD_DIR must be an absolute path.' >&2; exit 2 ;;
esac
app_path="$build_directory/Calendar Sync.app"

cd "$project_root"
xcrun swift build --configuration "$configuration" --arch "$architecture" --product CalendarSync
binary_directory="$(xcrun swift build --configuration "$configuration" --arch "$architecture" --show-bin-path)"

mkdir -p "$build_directory"
# Sign outside cloud-synced workspaces: file providers can add Finder metadata
# to an .app directory while signing is in progress.
staging_directory="$(mktemp -d "${TMPDIR:-/tmp}/calendar-sync.XXXXXX")"
trap 'rm -rf "$staging_directory"' EXIT
staging_app="$staging_directory/Calendar Sync.app"
mkdir -p "$staging_app/Contents/MacOS" "$staging_app/Contents/Resources"

cp "$binary_directory/CalendarSync" "$staging_app/Contents/MacOS/CalendarSync"
cp "$project_root/Resources/Info.plist" "$staging_app/Contents/Info.plist"
cp "$project_root/Resources/AppIcon.icns" "$staging_app/Contents/Resources/AppIcon.icns"
cp "$project_root/LICENSE" "$staging_app/Contents/Resources/LICENSE"
chmod 755 "$staging_app/Contents/MacOS/CalendarSync"
if [ "$configuration" = "release" ]; then
    # SwiftPM release builds retain debug metadata, including local source paths.
    # Strip that metadata before signing a distributable bundle.
    xcrun strip -S "$staging_app/Contents/MacOS/CalendarSync"
fi
plutil -lint "$staging_app/Contents/Info.plist"
codesign --force --sign - \
    --entitlements "$project_root/Resources/CalendarSync.entitlements" \
    "$staging_app"
codesign --verify --strict --verbose=2 "$staging_app"
actual_architecture="$(xcrun lipo -archs "$staging_app/Contents/MacOS/CalendarSync")"
if [ "$actual_architecture" != "$architecture" ]; then
    printf 'Expected architecture %s, found %s.\n' "$architecture" "$actual_architecture" >&2
    exit 1
fi

# Replace only the generated bundle, after the new bundle passes validation.
rm -rf "$app_path"
mv "$staging_app" "$app_path"
printf 'Built %s (%s)\n' "$app_path" "$architecture"
printf '%s\n' 'Ad-hoc signed for local use; not a notarized distribution build.'
