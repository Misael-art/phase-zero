# Varredura dos serviços de IA — lacunas e incoerências (2026-09-24)

Complementa `docs/audit/ai-config-review-2026-09-24.md` (IDs continuam a
série `AICR-`). Host `misael-jupiter`, branch `fix/ai-stack-remediation`.
Leitura + status; exceção no ledger abaixo.

## Achados

| ID | Sev | Dimensão | Superfície | Evidência | Recomendação |
|---|---|---|---|---|---|
| AICR-019 | **P0** | functional | `~/.hermes/config.yaml` | Arquivo com **0 bytes** desde 2026-09-23 22:44:57; `config.yaml.pz-bak` (3263 B) gravado 2 s antes, às 22:44:55; o boot seguinte foi às 22:47. `phasezero-hermes-router.service` fica em `failed` a cada 5 min (`status=1/FAILURE`, sem stderr): o auto-heal não consegue curar um arquivo vazio | Operador restaura de `config.yaml.pz-bak`; ver AICR-020/021 para a causa |
| AICR-020 | P1 | functional | runtime `~/.local/share/phasezero/runtime/hermes-router.sh` e `9router-hermes-provider.sh` (2026-08-30) | Diferem do repo. A cópia instalada ainda faz `open(path, "w").write(...)` (trunca no lugar, sem backup); o repo já faz escrita staged + `os.replace`. O timer roda a cópia antiga | `install_watch` só copia na instalação: reinstalar/atualizar a cópia quando o repo muda (hash no header + verificação no `status`) |
| AICR-021 | P1 | functional | `linux/ai/hermes-router.sh` (~L212), `9router-hermes-provider.sh` (~L225), `setup-hermes.sh` (~L316) | Escrita atômica sem `fsync` do tmp nem do diretório antes/depois do `os.replace`. Em btrfs (`findmnt` → `btrfs`), um shutdown logo após o rename pode deixar o arquivo com 0 bytes | `f.flush(); os.fsync(f.fileno())` no tmp e `os.fsync` do diretório; helper compartilhado |
| AICR-022 | P1 | gap | cópias instaladas × repo | Todas as cópias instaladas divergem do repo: 2 runtime do Hermes; `claude_code_manager.py` em `cc-installer` (2305 × 1878 linhas, ausente do git — AISR-010); runner Bonsai (fora do repo). Correções mergeadas não chegam ao host | Um `pz ai doctor --drift` (só leitura) comparando hash de cada cópia gerenciada com o repo; o `status` de cada família expõe `runtimeDrift` |
| AICR-023 | P1 | ux | `pz ai routing status` | `"health": true` com 12 de 15 conexões `unavailable` (401/403/429) e só `github` pronto. Os combos `phasezero-*` apontam para providers mortos sem aviso | `health` derivado da disponibilidade real; `availableProviders` × total; alerta quando um combo não tem nenhum membro disponível |
| AICR-024 | P2 | functional (redação) | `pz ai routing status` → `availability[].connectionName`, `lastError` | E-mail da conta em `connectionName`; `lastError` repassa o corpo cru do upstream | Mesma máscara de AICR-008; `lastError` reduzido a código + classe |
| AICR-025 | P2 | gap | `.mcp.json` do projeto (gerado, gitignored) | Ainda contém `mcp.bonsai-rx.org` após AISR-005: remover do catálogo não propaga para configs já geradas | `mcp sync` remove entradas gerenciadas que saíram do catálogo (marcador de origem) |
| AICR-026 | P2 | gap | `setup-ollama.sh`, `setup-open-webui.sh` | Só instalam: sem `status`, `dry-run` nem remoção | Mesmo contrato das demais famílias |
| AICR-027 | P2 | freshness (docs) | `docs/ai-tools.md` §Suporte implementado | A coluna "Desinstalação" promete remoção para opencode/openclaw/rtk; nenhum dos scripts tem `remove`/`uninstall`. Remoção existe só em omo, codexbar, omniroute e 9router | Implementar ou corrigir a tabela |
| AICR-028 | P2 | ux | `pz ai memory` | `pz ai setup memory` existe, `pz ai memory status` → `unknown ai subcommand` (rc=1). O status existe só dentro de `compat status` | Subcomando `memory (status|doctor)` ou alias documentado |
| AICR-029 | P2 | ux (contrato) | status de hermes, codexbar, odysseus, omo, mcp, desktop | Nenhum campo de topo `status`/`state`/`nextAction`/`summary`; todos os status saem rc=0 independentemente da saúde | Envelope comum (`schemaVersion`, `state`, `summary`, `nextAction`) e exit 0/2/3 conforme `ai-tools.md` |
| AICR-030 | P2 | ux (latência) | status | `workspaces doctor` 23,7 s; `auth status` 18,8 s; `hermes status` 15,8 s; `opencode status` 6,6 s (com o crash-loop do qwen ainda ativo) | Mesmo plano de AICR-010 |
| AICR-031 | P3 | functional | `~/.config/systemd/user/9router.service` | Unit legada (`node server.js`, disabled) convive com `phasezero-9router.service` | `repair` do 9Router remove a unit legada com backup |
| AICR-032 | P1 | functional (host) | `phasezero-qwenproxy.service` | `NRestarts` subiu de 81 para 1375 desde a auditoria; o host ainda não tem AISR-001 | Operador: `systemctl --user stop phasezero-qwenproxy` até o merge; depois `proxies restart qwenproxy` |

Coerente (sem achado): as 135 ações `ai.*` do catálogo despacham para
subcomandos existentes (`ai.updates-*` usa `pz updates`, intencional); todos os
listeners de IA (9Router :20128, proxies :3010/:3012, ai-memory :49374) estão só
em loopback.

## Ledger

- Leituras: `systemctl --user` (list/is-active/show NRestarts), journal das
  units, `ss -ltn`, 18 comandos `pz ai … status|doctor`, hostnames (sem valores)
  das configs de clientes MCP, diff das cópias instaladas × repo.
- **Execução fora da regra**: `bash ~/.local/share/phasezero/runtime/hermes-router.sh enforce`
  (2026-09-24 ~05:57), rodado para capturar o erro. `enforce` é `wire`
  (mutação). Saiu rc=1 sem stderr; `~/.hermes/config.yaml` manteve o mtime
  anterior (2026-09-23 22:44:57), ou seja, nada foi escrito. Registrado aqui
  por transparência.
- Não lido: credenciais Bonsai (bloqueio do classificador; ver AISR-007).
