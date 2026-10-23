#!/bin/zsh
# Builds the RamClean you sell: Release, signed with Developer ID, notarized, stapled, in a DMG.
# Output: build/release/RamClean-<version>.dmg. Step-by-step setup: docs/GO-LIVE.md.
#
# Needs two environment variables:
#   RAMCLEAN_SIGN_IDENTITY   your Developer ID certificate's name, e.g.
#                            "Developer ID Application: Amal Mehta (ABCDE12345)"
#   RAMCLEAN_NOTARY_PROFILE  the keychain profile made once with `xcrun notarytool store-credentials`
#
# --check: only check that everything is in place, then stop (builds and uploads nothing).
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { print -u2 "release.sh: $1"; exit 1 }

# 1. Refuse clearly when anything is missing, before building.
identity=${RAMCLEAN_SIGN_IDENTITY:-}
profile=${RAMCLEAN_NOTARY_PROFILE:-}
[[ -n $identity ]] || fail "RAMCLEAN_SIGN_IDENTITY isn't set. Set it to your Developer ID certificate's name:
  export RAMCLEAN_SIGN_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\"
To see the names in your keychain: security find-identity -v -p codesigning"
[[ $identity == "Developer ID Application: "* ]] || fail "RAMCLEAN_SIGN_IDENTITY must be a \"Developer ID Application: …\" certificate (got \"$identity\"). Apple Development and Mac App Distribution certificates can't be notarized for direct sale."
security find-identity -v -p codesigning | grep -qF "\"$identity\"" || fail "No valid signing identity named \"$identity\" in your keychain. Install the certificate (docs/GO-LIVE.md, step 1), then check with: security find-identity -v -p codesigning"
[[ -n $profile ]] || fail "RAMCLEAN_NOTARY_PROFILE isn't set. Make a profile once with:
  xcrun notarytool store-credentials RamCleanNotary --apple-id you@example.com --team-id TEAMID
then: export RAMCLEAN_NOTARY_PROFILE=RamCleanNotary"
team=${${identity##*\(}%\)}
[[ $team =~ '^[A-Z0-9]{10}$' ]] || fail "Couldn't read the team ID from \"$identity\" (expected it in brackets at the end)."

config=RamCleanCore/Sources/RamCleanCore/Licensing/ProductConfig.swift
grep -q "REPLACE-ME" $config && fail "$config still has REPLACE-ME placeholders (checkout, website or appcast link). Fill them in first (docs/GO-LIVE.md)."
grep -qE "lemonSqueezy(Store|Product)ID: 0," $config && fail "$config has no Lemon Squeezy store or product ID yet, so every copy would be unlocked. Fill them in first (docs/GO-LIVE.md)."
public_key=$(sed -n 's/^ *SUPublicEDKey: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' project.yml)
[[ -n $public_key ]] || fail "SUPublicEDKey in project.yml is empty, so the app couldn't install updates. Run Sparkle's generate_keys and paste the public key (docs/GO-LIVE.md)."
xcrun notarytool history --keychain-profile "$profile" > /dev/null 2>&1 || fail "notarytool can't use the keychain profile \"$profile\". Make it with: xcrun notarytool store-credentials \"$profile\" --apple-id you@example.com --team-id $team"

version=$(sed -n 's/^ *CFBundleShortVersionString: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' project.yml)
build_number=$(sed -n 's/^ *CFBundleVersion: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' project.yml)
echo "Ready to release RamClean $version ($build_number), signed by $identity, notarized with profile \"$profile\"."
[[ ${1:-} == "--check" ]] && exit 0

# 2. Build Release with the hardened runtime notarization requires.
out=build/release
rm -rf $out && mkdir -p $out
xcodegen generate --quiet
log=$out/xcodebuild.log
if ! xcodebuild -project RamClean.xcodeproj -scheme RamClean -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData -archivePath $out/RamClean.xcarchive archive \
  CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" > $log 2>&1; then
  grep -E "error:" $log || tail -20 $log
  fail "Build failed. Full log: $log"
fi
app=$out/RamClean.app
cp -R $out/RamClean.xcarchive/Products/Applications/RamClean.app $app

# 3. Sign Sparkle's helpers, then the app, inside out (Sparkle's documented order, no --deep).
sign() { codesign --force --timestamp --options runtime --sign "$identity" "$@" }
sparkle=$app/Contents/Frameworks/Sparkle.framework
sign $sparkle/Versions/B/XPCServices/Installer.xpc
sign --preserve-metadata=entitlements $sparkle/Versions/B/XPCServices/Downloader.xpc
sign $sparkle/Versions/B/Autoupdate
sign $sparkle/Versions/B/Updater.app
sign $sparkle
sign --entitlements App/RamClean.entitlements $app
codesign --verify --deep --strict --verbose=2 $app

# 4. Notarize and staple the app, so it opens without a warning even when copied out of the DMG.
ditto -c -k --keepParent $app $out/RamClean.zip
xcrun notarytool submit $out/RamClean.zip --keychain-profile "$profile" --wait
xcrun stapler staple $app
rm $out/RamClean.zip

# 5. DMG with an Applications shortcut to drag onto; sign, notarize and staple it too.
dmg=$out/RamClean-$version.dmg
staging=$out/dmg
mkdir -p $staging && cp -R $app $staging/ && ln -s /Applications $staging/Applications
hdiutil create -volname "RamClean" -srcfolder $staging -ov -format UDZO $dmg > /dev/null
rm -rf $staging
codesign --timestamp --sign "$identity" $dmg
xcrun notarytool submit $dmg --keychain-profile "$profile" --wait
xcrun stapler staple $dmg
spctl --assess --type open --context context:primary-signature --verbose $dmg

echo "Built $dmg"
echo "Next: put it in your updates folder and run Sparkle's generate_appcast there (docs/GO-LIVE.md, step 5)."
