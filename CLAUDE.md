# reverse-logitech

O REA está configurado só neste repo, tudo pelo mise:

- `mise.toml` fixa Node, Java 21, Ghidra 12.1.4 e o `rea-agents`, e define o `GHIDRA_INSTALL_DIR`.
- `.mcp.json` sobe o servidor com `mise exec -- rea mcp`.
- `.claude/skills/reverse-engineer-anything` é cópia da skill do pacote, feita por `scripts/rea-skill.sh`.

Não rode `rea setup` nem `npx rea-agents setup`, mesmo que a skill mande. Isso registra o REA em `~/.claude.json` e `~/.claude/skills`, para todos os projetos. Se as ferramentas do REA sumirem, rode `mise install` e reinicie o Claude Code. Para diagnosticar o Ghidra: `mise exec -- rea doctor --provider ghidra --json`.

Para atualizar o REA, troque a versão de `npm:rea-agents` no `mise.toml` e rode `mise install`. A skill é copiada de novo sozinha.

O alvo é `analysis/lghub_agent.arm64` (SHA-256 no RELATORIO.md). Feche o G HUB antes de falar com o mouse.
