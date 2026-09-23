#!/usr/bin/env bash
# Refresh the bundled mihomo kernel from the official release. The binaries are stored in the tree.
set -euo pipefail
ver="${1:-v1.19.31}"
root="$(cd "$(dirname "$0")/.." && pwd)/src/Linux/kernel"
base="https://github.com/MetaCubeX/mihomo/releases/download/${ver}"
mkdir -p "$root/linux-x64" "$root/linux-arm64"
fetch() {
  local name="$1" dest="$2"
  echo "GET $name"
  curl -fL --retry 3 --retry-delay 2 -o "/tmp/${name}" "${base}/${name}"
  gzip -dc "/tmp/${name}" > "$dest"
  chmod 755 "$dest"
  rm -f "/tmp/${name}"
}
fetch "mihomo-linux-amd64-compatible-${ver}.gz" "$root/linux-x64/mihomo" \
  || fetch "mihomo-linux-amd64-${ver}.gz" "$root/linux-x64/mihomo"
fetch "mihomo-linux-arm64-${ver}.gz" "$root/linux-arm64/mihomo"
printf '%s\n' "$ver" > "$root/VERSION"
"$root/linux-x64/mihomo" -v
