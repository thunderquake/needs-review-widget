#!/usr/bin/env bash
# Build, install to /Applications and make the widget host pick up the new build.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate >/dev/null
osascript -e 'tell application "NeedsReview" to quit' 2>/dev/null || true
xcodebuild -project NeedsReview.xcodeproj -scheme NeedsReview -configuration Debug \
  -derivedDataPath build -allowProvisioningUpdates build 2>&1 \
  | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" || true

rm -rf /Applications/NeedsReview.app
cp -R build/Build/Products/Debug/NeedsReview.app /Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f /Applications/NeedsReview.app
killall NeedsReviewWidget 2>/dev/null || true
killall chronod 2>/dev/null || true
echo "installed"
