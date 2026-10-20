#!/bin/sh
# O zip do Ghidra não traz o decompilador para macOS arm64; este script compila e instala.
# O mise chama depois de instalar o Ghidra.
set -eu
[ "$(uname -sm)" = "Darwin arm64" ] || exit 0
dir="${MISE_TOOL_INSTALL_PATH:-$GHIDRA_INSTALL_DIR}/Ghidra/Features/Decompiler"
out="$dir/os/mac_arm_64/decompile"
[ -x "$out" ] && exit 0
make -C "$dir/src/decompile/cpp" ghidra_opt ARCH_TYPE="-arch arm64" OSDIR=mac_arm_64
mkdir -p "$(dirname "$out")"
install -m 755 "$dir/src/decompile/cpp/ghidra_opt" "$out"
