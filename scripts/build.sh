#!/bin/zsh
# Compile SwiftCut en Release et place l'app dans build/SwiftCut.app.
#   ./scripts/build.sh            → compile
#   ./scripts/build.sh --install  → compile puis copie dans /Applications
set -euo pipefail
cd "${0:A:h}/.."

xcodebuild -quiet \
  -project SwiftCut.xcodeproj \
  -scheme SwiftCut \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData \
  build

rm -rf build/SwiftCut.app
ditto build/DerivedData/Build/Products/Release/SwiftCut.app build/SwiftCut.app
echo "✓ build/SwiftCut.app"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/SwiftCut.app
  ditto build/SwiftCut.app /Applications/SwiftCut.app
  echo "✓ installée dans /Applications"
fi
