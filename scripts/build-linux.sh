#!/usr/bin/env bash
# Usage: build-linux.sh [x64|arm64]
set -euo pipefail
arch="${1:-x64}"
case "$arch" in
  x64|arm64) ;;
  *) echo "usage: build-linux.sh [x64|arm64]" >&2; exit 1 ;;
esac
root="$(cd "$(dirname "$0")/.." && pwd)"
dotnet="${DOTNET:-dotnet}"
if ! command -v "$dotnet" >/dev/null 2>&1 && [[ -x "${HOME}/.dotnet/dotnet" ]]; then
  dotnet="${HOME}/.dotnet/dotnet"
fi
rid="linux-$arch"
kernel="$root/src/Linux/kernel/$rid/mihomo"
if [[ ! -f "$kernel" ]]; then
  bash "$root/scripts/fetch-mihomo.sh"
fi
if [[ "${SKIP_TESTS:-}" != 1 ]]; then
  if [[ -z "${CODEX_SWITCH_TEST_KERNEL:-}" && "$(uname -s)" == Linux ]]; then
    case "$(uname -m)" in
      x86_64) test_arch=x64 ;;
      aarch64|arm64) test_arch=arm64 ;;
      *) test_arch= ;;
    esac
    if [[ -n "$test_arch" && -f "$root/src/Linux/kernel/linux-$test_arch/mihomo" ]]; then
      export CODEX_SWITCH_TEST_KERNEL="$root/src/Linux/kernel/linux-$test_arch/mihomo"
    fi
  fi
  "$dotnet" run --project "$root/tests/Core.Tests/Core.Tests.csproj" -c Release
fi
"$dotnet" publish "$root/src/Linux/CodexSwitch.Linux.csproj" -c Release -r "$rid" --self-contained true \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true \
  -o "$root/dist/$rid"
chmod 755 "$root/dist/$rid/codex-switch"
if [[ -f "$root/dist/$rid/kernel/$rid/mihomo" ]]; then
  chmod 755 "$root/dist/$rid/kernel/$rid/mihomo"
fi
echo "Built: $root/dist/$rid/codex-switch"
