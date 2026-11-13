#!/bin/sh
# Runs the layout check of the long languages: a UI test that launches the
# app once per language (-AppleLanguages) against the fake paddock, and
# reads the accessibility tree from outside, as VoiceOver does. macOS
# builds the tree of SwiftUI only for such a client.
#
#   Scripts/check-languages.sh          German and Russian
#   Scripts/check-languages.sh fr it    other languages
set -e
cd "$(dirname "$0")/.."
langs=${*:-de ru}
TEST_RUNNER_PADDOCK_LAYOUT_LANGUAGES=$(echo "$langs" | tr ' ' ',') \
xcodebuild -project PaddockLauncher.xcodeproj -scheme PaddockLauncher -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${DERIVED:-build/dd}" test \
  -only-testing:PaddockLauncherUITests/LanguageLayoutUITests
