#!/bin/zsh
# Build WenaSync and install + launch it on the first iPhone Xcode can see.
# Requires: iPhone plugged in via cable, unlocked, "Trust This Computer" accepted,
# Developer Mode enabled on the phone, an Apple ID signed in to Xcode
# (Xcode > Settings > Accounts), and TEAM set to that account's team ID.
set -e
cd "$(dirname "$0")/WenaSync.swiftpm"
TEAM="${TEAM:-}"
if [ -z "$TEAM" ]; then echo "Set TEAM to your Apple Development Team ID, e.g.  TEAM=ABCDE12345 ./install_iphone.sh"; echo "Find it in Xcode > Settings > Accounts > your Apple ID > Team, or at developer.apple.com/account."; exit 1; fi
DD="${DD:-/tmp/wenasync-dd}"

UDID=$(xcrun devicectl list devices --json-output /tmp/devs.json >/dev/null 2>&1; python3 -c "
import json;d=json.load(open('/tmp/devs.json'))
for x in d.get('result',{}).get('devices',[]):
    if x.get('hardwareProperties',{}).get('platform')=='iOS':
        print(x['identifier']); break")
if [ -z "$UDID" ]; then echo "No iPhone found. Plug it in, unlock it, tap Trust."; exit 1; fi
echo "Using device $UDID"

NAME=$(python3 -c "
import json;d=json.load(open('/tmp/devs.json'))
for x in d.get('result',{}).get('devices',[]):
    if x.get('hardwareProperties',{}).get('platform')=='iOS':
        print(x['deviceProperties']['name']); break")
echo "Device name: $NAME"
xcodebuild -scheme WenaSync -destination "platform=iOS,name=$NAME" -derivedDataPath "$DD" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic build | grep -E "error:|warning: Signing|BUILD" || true

APP=$(find "$DD/Build/Products" -name "WenaSync.app" -path "*iphoneos*" | head -1)
[ -n "$APP" ] || { echo "Build output not found"; exit 1; }
echo "Installing $APP"
xcrun devicectl device install app --device "$UDID" "$APP"
echo "Launching"
xcrun devicectl device process launch --device "$UDID" com.animesh.wenasync || true
echo "Done. If iOS refuses to open it: Settings > General > VPN & Device Management > trust your Apple ID; and enable Developer Mode under Settings > Privacy & Security if prompted."
