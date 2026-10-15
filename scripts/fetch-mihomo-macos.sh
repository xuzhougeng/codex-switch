#!/usr/bin/env bash
# Download the pinned official macOS kernel and verify the release asset digest.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
kernel_version="$(cat "$root/src/Linux/kernel/VERSION")"
case "$(uname -m)" in
  arm64) kernel_arch=arm64 ;;
  x86_64) kernel_arch=amd64 ;;
  *) echo "Unsupported macOS architecture" >&2; exit 1 ;;
esac
asset="mihomo-darwin-${kernel_arch}-${kernel_version}.gz"
expected="$(awk -v asset="$asset" '$2 == asset { print $1 }' "$root/src/macOS/kernel/SHA256SUMS")"
if [[ -z "$expected" ]]; then echo "No pinned checksum for $asset" >&2; exit 1; fi
kernel_dir="$root/dist/mihomo-macos"
mkdir -p "$kernel_dir"
archive="$(mktemp)"
trap 'rm -f "$archive"' EXIT
curl -fL --retry 3 --retry-delay 2 -o "$archive" "https://github.com/MetaCubeX/mihomo/releases/download/${kernel_version}/${asset}"
actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
if [[ "$actual" != "$expected" ]]; then echo "mihomo checksum mismatch" >&2; exit 1; fi
gzip -dc "$archive" > "$kernel_dir/mihomo"
chmod 755 "$kernel_dir/mihomo"
"$kernel_dir/mihomo" -v
