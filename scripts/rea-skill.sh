#!/bin/sh
# Copia a skill do pacote do REA para .claude/skills. O mise chama depois de
# instalar o rea-agents, então a skill segue a versão do mise.toml.
set -eu
root="${MISE_CONFIG_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
pkg="${MISE_TOOL_INSTALL_PATH:-$(mise where npm:rea-agents)}"
src=$(find "$pkg" -type d -path '*/rea-agents/skills/reverse-engineer-anything' | head -1)
[ -n "$src" ] || { echo "skill do REA não encontrada em $pkg" >&2; exit 1; }
rm -rf "$root/.claude/skills/reverse-engineer-anything"
mkdir -p "$root/.claude/skills"
cp -R "$src" "$root/.claude/skills/"
