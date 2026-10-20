#!/bin/sh
# Monta app/build/Rato.app, e app/build/Rato.dmg com --dmg. A versão vem do version.txt.
# SIGN_IDENTITY assina para distribuir (Developer ID, hardened runtime); sem ela, a
# assinatura é ad hoc. NOTARY_KEY_ID, NOTARY_ISSUER_ID e NOTARY_KEY_P8 adicionam a
# notarização.
set -e
cd "$(dirname "$0")"
swift build -c release --product Rato
app=build/Rato.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Rato" "$app/Contents/MacOS/"
# AppIcon.icon é um documento do Icon Composer. O actool gera o Assets.car, sem o qual
# o macOS 26 desenha o ícone dentro de uma moldura cinza, e um .icns para sistemas antigos.
xcrun actool AppIcon.icon --compile "$app/Contents/Resources" --platform macosx \
  --minimum-deployment-target 13.0 --app-icon AppIcon \
  --output-partial-info-plist "$(mktemp -d)/icon.plist" > /dev/null
cp Info.plist "$app/Contents/"
version=$(cat ../version.txt)
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$version" "$app/Contents/Info.plist"

if [ -n "$SIGN_IDENTITY" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$app"
else
  codesign --force --sign - "$app"
fi

if [ -n "$SIGN_IDENTITY" ] && [ -n "$NOTARY_KEY_ID" ]; then
  key=$(mktemp)
  trap 'rm -f "$key"' EXIT
  printf '%s' "$NOTARY_KEY_P8" > "$key"
  ditto -c -k --keepParent "$app" build/notarize.zip
  xcrun notarytool submit build/notarize.zip --key "$key" --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" --wait
  xcrun stapler staple "$app"
  rm build/notarize.zip
fi

if [ "$1" = --dmg ]; then
  stage=$(mktemp -d)
  cp -R "$app" "$stage/"
  ln -s /Applications "$stage/Applications"
  hdiutil create -volname Rato -srcfolder "$stage" -ov -format UDZO build/Rato.dmg
  rm -rf "$stage"
fi
echo "$app"
