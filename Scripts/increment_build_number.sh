#!/bin/sh
# Adds 1 to the build number on every build (running and testing both build first)
# and writes it into the built app's Info.plist as CFBundleVersion.
# BuildNumber.txt holds the most recent build number; edit it to change the start.
set -e

FILE="${SRCROOT}/BuildNumber.txt"
NUMBER=$(tr -cd '0-9' < "$FILE" 2>/dev/null || true)
NUMBER=$(( ${NUMBER:-0} + 1 ))
echo "$NUMBER" > "$FILE"

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NUMBER" "${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
echo "Build number: $NUMBER"
