#!/bin/zsh
# Builds RamClean.app into build/ (Release). Needs Xcode 16+ and xcodegen (brew install xcodegen).
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project RamClean.xcodeproj -scheme RamClean -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData build 2>&1 | grep -E "error:|BUILD" || true
rm -rf build/RamClean.app
cp -R build/DerivedData/Build/Products/Release/RamClean.app build/RamClean.app
echo "Built build/RamClean.app — open it with: open build/RamClean.app"
