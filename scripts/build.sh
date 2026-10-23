#!/bin/zsh
# Builds RamClean.app into build/ (Release). Needs Xcode 16+ and xcodegen (brew install xcodegen).
# --run: quit any RamClean that's running (an older copy may have opened at login) and open the new build.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcodegen generate --quiet
log=build/xcodebuild.log
# Ad-hoc signing gives each build a new identity, so macOS forgets RamClean's Accessibility
# access every rebuild. A "RamClean Development" certificate in your keychain keeps it stable
# (docs/INSTRUCTIONS.md says how to make one).
sign=()
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"RamClean Development"'; then
  sign=(CODE_SIGN_IDENTITY="RamClean Development")
  echo "Signing with RamClean Development"
fi
if ! xcodebuild -project RamClean.xcodeproj -scheme RamClean -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData "${sign[@]}" build > "$log" 2>&1; then
  grep -E "error:" "$log" || tail -20 "$log"
  echo "Build failed; build/RamClean.app is unchanged. Full log: $log" >&2
  exit 1
fi
grep -E "BUILD" "$log" || true
rm -rf build/RamClean.app
cp -R build/DerivedData/Build/Products/Release/RamClean.app build/RamClean.app

if [[ "${1:-}" == "--run" ]]; then
  running() { pgrep -f "RamClean.app/Contents/MacOS/RamClean" > /dev/null }
  # Each quit reaches one copy, so keep asking until none are left (a Debug build may be running too).
  for _ in {1..20}; do
    running || break
    osascript -e 'tell application id "com.amalmehta.RamClean" to quit' > /dev/null 2>&1 || true
    sleep 0.5
  done
  if running; then echo "RamClean didn't quit; quit it yourself and run: open build/RamClean.app" >&2; exit 1; fi
  open build/RamClean.app
  echo "Built and opened build/RamClean.app"
else
  echo "Built build/RamClean.app — open it with: open build/RamClean.app (or build with --run)"
fi
