#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 <flutter-bundle> <version> <x64|arm64> <output-directory>" >&2
  exit 2
fi
bundle=$(realpath "$1")
version=$2
flutter_arch=$3
output=$(realpath -m "$4")
case "$flutter_arch" in
  x64) deb_arch=amd64 ;;
  arm64) deb_arch=arm64 ;;
  *) echo "Unsupported architecture: $flutter_arch" >&2; exit 2 ;;
esac
if [[ ! -x "$bundle/quicksend_native" ]]; then
  echo "Flutter executable missing from $bundle" >&2
  exit 1
fi
mkdir -p "$output"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
install -d "$root/DEBIAN" "$root/usr/lib/quicksend" "$root/usr/bin" "$root/usr/share/applications"
cp -a "$bundle/." "$root/usr/lib/quicksend/"
cat > "$root/usr/bin/quicksend" <<'LAUNCHER'
#!/bin/sh
exec /usr/lib/quicksend/quicksend_native "$@"
LAUNCHER
chmod 0755 "$root/usr/bin/quicksend"
cat > "$root/DEBIAN/control" <<CONTROL
Package: quicksend
Version: $version
Section: net
Priority: optional
Architecture: $deb_arch
Depends: libgtk-3-0, libblkid1, liblzma5, libstdc++6
Maintainer: QuickSend contributors
Description: QuickSend Chinese-language LAN transfer client
 Native Flutter application for discovering LAN devices, group chat, and file sharing.
CONTROL
cat > "$root/usr/share/applications/quicksend.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=QuickSend
Comment=局域网文件传输与群聊
Exec=quicksend
Terminal=false
Categories=Network;FileTransfer;
DESKTOP
dpkg-deb --build --root-owner-group "$root" "$output/QuickSend-v${version}-linux-${flutter_arch}.deb"
