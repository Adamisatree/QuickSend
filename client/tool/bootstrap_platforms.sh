#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

flutter create --platforms=android,ios,linux,macos,windows --org com.quicksend --project-name quicksend_native --no-pub .

# LAN WebSockets carry only authenticated ciphertext; allow the local relay socket on Android.
python3 - <<'PY'
from pathlib import Path
manifest = Path('android/app/src/main/AndroidManifest.xml')
if manifest.exists():
    text = manifest.read_text()
    if 'android.permission.INTERNET' not in text:
        text = text.replace('<manifest ', '<manifest xmlns:android="http://schemas.android.com/apk/res/android" ', 1) if 'xmlns:android=' not in text else text
        text = text.replace('<application', '    <uses-permission android:name="android.permission.INTERNET" />\n    <application', 1)
    if 'android:usesCleartextTraffic=' not in text:
        text = text.replace('<application', '<application android:usesCleartextTraffic="true"', 1)
    manifest.write_text(text)

plist = Path('ios/Runner/Info.plist')
if plist.exists():
    text = plist.read_text()
    if 'NSLocalNetworkUsageDescription' not in text:
        text = text.replace('</dict>', '    <key>NSLocalNetworkUsageDescription</key>\n    <string>QuickSend connects directly to devices on your local network.</string>\n    <key>NSAppTransportSecurity</key>\n    <dict><key>NSAllowsLocalNetworking</key><true/></dict>\n</dict>')
        plist.write_text(text)
PY
