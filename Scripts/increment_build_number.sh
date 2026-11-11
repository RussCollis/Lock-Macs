#!/bin/sh
# Adds 1 to the build number on every build (running and testing both build first).
# BuildNumber.txt holds the most recent build number; edit it to change the start.
#
# Xcode writes CURRENT_PROJECT_VERSION into the app's Info.plist as CFBundleVersion
# after this script runs, so patching the built Info.plist doesn't stick. Instead the
# script sets CURRENT_PROJECT_VERSION in the project to the number the *next* build
# will use. Build settings are read when a build starts, so each build shows the
# number this script has just written to BuildNumber.txt.
set -e

FILE="${SRCROOT}/BuildNumber.txt"
PROJECT="${PROJECT_FILE_PATH}/project.xcproj"

NUMBER=$(tr -cd '0-9' < "$FILE" 2>/dev/null || true)
NUMBER=$(( ${NUMBER:-0} + 1 ))
echo "$NUMBER" > "$FILE"

NEXT=$(( NUMBER + 1 ))
sed -i '' -E "s/(\"CURRENT_PROJECT_VERSION\": \")[0-9]*\"/\1${NEXT}\"/" "$PROJECT"

echo "Build number: $NUMBER (this build shows ${CURRENT_PROJECT_VERSION})"
