#!/bin/bash
# Compilation complète de l'app iOS pour le simulateur.
#
# Un simple « swiftc -typecheck » ne suffit pas : il laisse passer des erreurs que
# seule la compilation réelle signale (un retour manquant dans un getter, par
# exemple). On construit donc pour de vrai, et on ne garde que ce qui compte.
set -u
cd "$(dirname "$0")"

DEVICE="${MBA_DEVICE:-00F746E3-8C33-452B-854F-8EAE8531EAFB}"   # iPhone 17e, iOS 26.5

OUTPUT=$(xcodebuild -project MyBeautifulAdmin.xcodeproj \
  -scheme MyBeautifulAdmin \
  -destination "id=$DEVICE" \
  -configuration Debug \
  build 2>&1)

echo "$OUTPUT" | grep -E "error:|warning:" | grep -v "AppIntents.framework" | sort -u
if echo "$OUTPUT" | grep -q "BUILD SUCCEEDED"; then
  echo "✅ build OK"
else
  echo "❌ build FAILED"
  exit 1
fi
