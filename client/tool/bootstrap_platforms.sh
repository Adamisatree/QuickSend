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
    text = text.replace('android:label="quicksend_native"', 'android:label="QuickSend"')
    manifest.write_text(text)

for plist_path in (Path('ios/Runner/Info.plist'), Path('macos/Runner/Info.plist')):
    plist = plist_path
    if not plist.exists():
        continue
    text = plist.read_text()
    text = text.replace('<key>CFBundleName</key>\n\t<string>quicksend_native</string>', '<key>CFBundleName</key>\n\t<string>QuickSend</string>')
    if '<key>CFBundleDisplayName</key>' not in text:
        text = text.replace('<key>CFBundleName</key>', '<key>CFBundleDisplayName</key>\n\t<string>QuickSend</string>\n\t<key>CFBundleName</key>', 1)
    plist.write_text(text)

plist = Path('ios/Runner/Info.plist')
if plist.exists():
    text = plist.read_text()
    if 'NSLocalNetworkUsageDescription' not in text:
        text = text.replace('</dict>', '    <key>NSLocalNetworkUsageDescription</key>\n    <string>QuickSend 需要访问局域网以发现附近设备并传输文件。</string>\n    <key>NSAppTransportSecurity</key>\n    <dict><key>NSAllowsLocalNetworking</key><true/></dict>\n</dict>')
        plist.write_text(text)
PY
