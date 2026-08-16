#!/bin/bash
# Contrôle de compilation de l'app iOS sans passer par actool.
# Le runtime de simulateur installé (26.4) est plus ancien que le SDK (26.5), ce
# qui bloque la compilation du catalogue d'assets ; le typecheck Swift, lui,
# couvre l'intégralité du code.
set -u
cd "$(dirname "$0")"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun swiftc -typecheck -parse-as-library \
  -sdk "$SDK" -target arm64-apple-ios18.0 -swift-version 6 \
  -strict-concurrency=complete \
  $(find MBA -name '*.swift') "$@"
