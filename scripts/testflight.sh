#!/bin/bash
set -euo pipefail

for name in IOS_BUNDLE_ID APPLE_TEAM_ID IOS_DISTRIBUTION_P12_BASE64 IOS_DISTRIBUTION_P12_PASSWORD IOS_PROVISION_PROFILE_BASE64; do
  if [[ -z "${!name:-}" ]]; then echo "Missing configuration: $name" >&2; exit 1; fi
done
if [[ "${UPLOAD_TO_TESTFLIGHT:-false}" == true ]]; then
  for name in APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID APP_STORE_CONNECT_PRIVATE_KEY; do
    if [[ -z "${!name:-}" ]]; then echo "Missing configuration: $name" >&2; exit 1; fi
  done
fi

SIGNING_DIR="$(mktemp -d "${RUNNER_TEMP}/localcamera.XXXXXX")"
KEYCHAIN_PATH="$SIGNING_DIR/signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"
PROFILE_PATH=""
API_KEY_PATH=""
cleanup() {
  security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
  [[ -z "$PROFILE_PATH" ]] || rm -f "$PROFILE_PATH"
  [[ -z "$API_KEY_PATH" ]] || rm -f "$API_KEY_PATH"
  rm -rf "$SIGNING_DIR"
}
trap cleanup EXIT
export SIGNING_DIR
python3 - <<'PY'
import os, base64, pathlib
p = pathlib.Path(os.environ['SIGNING_DIR'])
for name, filename in [('IOS_DISTRIBUTION_P12_BASE64','certificate.p12'), ('IOS_PROVISION_PROFILE_BASE64','profile.mobileprovision')]:
    (p / filename).write_bytes(base64.b64decode(os.environ[name]))
PY
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$SIGNING_DIR/certificate.p12" -P "$IOS_DISTRIBUTION_P12_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH" >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
security list-keychains -d user -s "$KEYCHAIN_PATH"
security cms -D -i "$SIGNING_DIR/profile.mobileprovision" > "$SIGNING_DIR/profile.plist"
PROFILE_UUID="$(/usr/libexec/PlistBuddy -c 'Print UUID' "$SIGNING_DIR/profile.plist")"
PROFILE_PATH="$HOME/Library/MobileDevice/Provisioning Profiles/$PROFILE_UUID.mobileprovision"
mkdir -p "$(dirname "$PROFILE_PATH")"
cp "$SIGNING_DIR/profile.mobileprovision" "$PROFILE_PATH"
export PROFILE_UUID
mkdir -p build
python3 - <<'PY'
import os, plistlib
options = {'method':'app-store-connect', 'signingStyle':'manual',
           'teamID':os.environ['APPLE_TEAM_ID'], 'signingCertificate':'Apple Distribution',
           'provisioningProfiles':{os.environ['IOS_BUNDLE_ID']:os.environ['PROFILE_UUID']},
           'manageAppVersionAndBuildNumber':False, 'uploadSymbols':True}
with open('build/ExportOptions.plist','wb') as f: plistlib.dump(options,f)
PY
xcodebuild -project LocalCamera.xcodeproj -scheme LocalCamera -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/LocalCamera.xcarchive \
  PRODUCT_BUNDLE_IDENTIFIER="$IOS_BUNDLE_ID" DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY='Apple Distribution' \
  PROVISIONING_PROFILE_SPECIFIER="$PROFILE_UUID" \
  CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER}.${GITHUB_RUN_ATTEMPT}" archive
xcodebuild -exportArchive -archivePath build/LocalCamera.xcarchive \
  -exportOptionsPlist build/ExportOptions.plist -exportPath build/export

if [[ "${UPLOAD_TO_TESTFLIGHT:-false}" == true ]]; then
  API_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
  mkdir -p "$(dirname "$API_KEY_PATH")"
  printf '%s' "$APP_STORE_CONNECT_PRIVATE_KEY" > "$API_KEY_PATH"
  chmod 600 "$API_KEY_PATH"
  xcrun altool --upload-app --type ios --file build/export/LocalCamera.ipa \
    --apiKey "$APP_STORE_CONNECT_KEY_ID" --apiIssuer "$APP_STORE_CONNECT_ISSUER_ID"
fi
