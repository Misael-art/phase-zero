# Contrarrevisão R0/R1 — a82e2cc

**Aceite parcial.** Seis commits existem e correções centrais passaram nos testes. R0/R1 ainda não podem encerrar: cinco lacunas reproduzidas, incluindo P0 no caminho de parada do restore. Não confundir fechamento do defeito específico de cp parcial com certificação integral de restore.

## O que foi confirmado

| Área | Parecer |
|---|---|
| REV-001, cp parcial | Teste passou: volume falho entra no rollback; erro de rollback reporta recoveryRequired. Falta cobrir todos os pontos de falha; P0 residual descrito abaixo. |
| REV-002, SQLite | API agora lê origem viva; writer concorrente + restore + integrity_check passaram. Classificação TSDB e reason ainda falham. Consistência entre banco e anexos não certificada. |
| REV-003, ordem | cmd_down foi movido antes de tar; isso não garante parada efetiva quando retorno interno é ocultado. |
| REV-004 | Parser de documento completo passou, inclusive pretty/compact/envelope. |
| REV-005/006 | False e troca de host invalidam estado existente; callback de pairing em voo ainda recompõe estado incorreto. |
| REV-007 | Perfil chega ao argumento e profile.active; conjuntos de serviços não são resolvidos pelo perfil. |
| REV-018 | Suíte inteira passou com docker externo sombreado por exit127; mensagem rc69 de maturidade confirmada. Nenhum daemon real usado. |
| Evidência/roadmap | Reabertura in_progress é adequada. Tier implemented nas linhas ainda pending/blocked deve virar planned/unproven quando não existe implementação. |

## Achados para devolver ao agente

### R01-001 — P0 — Restore prossegue quando Compose down falha

Fonte: `linux/server/homelab-stack.sh:742`. Relacionado: REV-001/003.

cmd_restore chama cmd_down dentro de if !. Bash suprime errexit nesse contexto; run_compose down retorna 42, mas pz_info devolve 0. Snapshot e restauração continuam sobre possível escritor vivo. Probe usa funções reais, set -e e Compose fake; resultado rc=0/ok=true, original substituído.

Correção: Adicionar propagação explícita (run_compose down || return) e provar parada do conjunto correto antes do snapshot; nenhuma escrita após falha.

Aceite: cmd_down real + run_compose fake exit42: restore não captura/aplica arquivos e devolve erro. Não substituir cmd_down por stub que já retorna falha.

### R01-002 — P1 — Pareamento tardio associa sucesso ao host errado

Fonte: `linux/ui_native/pages/homelab.py:587`. Relacionado: REV-005/006.

Callback lê _selected_host; não captura alias iniciado e ignora hostAlias da resposta. Troca A→B durante pairing; resposta A pareada marca B e avança a profile. Reproduzido.

Correção: Capturar alias e operationId na criação do processo; comparar resposta e seleção; invalidar _pair_advance/callback ao trocar host.

Aceite: Pair A em voo, selecionar B, entregar sucesso/falha A: B continua não pareado, etapa não avança, nenhum ping/execução em B por resposta A.

### R01-003 — P1 — Prepare persiste perfil, mas não resolve seus serviços

Fonte: `linux/server/homelab-stack.sh:1439`. Relacionado: REV-007.

--profile é ecoado/persistido; apps ainda vêm de PREPARE_APPS ou default_prepare_apps. Planos reais edge e assistant-private retornam Jellyfin/Syncthing/Vaultwarden/Uptime Kuma iguais. Assistant-private declara outros serviços no registry. Perfis não instaláveis continuam aceitos por prepare: known não é installable.

Correção: Resolver conjunto/dependências/maturidade/recursos do perfil no plano; bloquear perfil não instalável antes de mutação, ou deixar explícito que seleção é só orçamento. Não declarar appliance entregue por profile.active.

Aceite: Perfis distintos com conjuntos distintos produzem plano e execução respectivos; preview bloqueado com razão; plano inclui seleção de apps e orçamento, execução usa exatamente conjunto revisado.

### R01-004 — P2 — Reason de backup desaparece na subshell

Fonte: `linux/server/homelab-stack.sh:966`. Relacionado: REV-002.

stage_volume_consistent atribui STAGE_REASON dentro de $(...). A variável não retorna ao pai. Probe de PG_VERSION retorna staged-tar false e reason vazio.

Correção: Retornar método/consistência/motivo em documento estruturado único; não usar variável lateral de subshell.

Aceite: Backup de marcador PostgreSQL e falha sqlite geram manifest e resultado com reason não vazio e correto.

### R01-005 — P1 — TSDB Prometheus classificada como consistente

Fonte: `linux/server/homelab-stack.sh:869`. Relacionado: REV-002.

Detecção exige wal e chunks/index diretamente na raiz; layout normal usa chunks_head e diretórios de blocos com chunks/index internos. Fixture desse layout retorna staged-tar true.

Correção: Classificar engine pelo manifesto/receita e usar snapshot suportado; heurística residual deve reconhecer layout real e falhar conservadoramente.

Aceite: Raiz com wal/, chunks_head/, <block>/index e <block>/chunks nunca recebe consistent:true por mera cópia viva; snapshot real por API tem teste próprio.

Layout TSDB conferido na [documentação oficial Prometheus](https://prometheus.io/docs/prometheus/latest/storage/). Ela documenta diretórios de blocos, `chunks_head` e `wal`, e recomenda snapshot para backup. Inferência local: condição atual não reconhece esse layout; fixture confirma classificação equivocada.

## Testes e limites

- [78 testes Python passaram](pytest-user-fixture.txt): Player 40 + agent/web 38. Primeira execução sem USER no ambiente restrito resultou em 77/1; reexecução com USER/LOGNAME de fixture passou. Falha inicial preservada em [pytest.txt](pytest.txt); não atribuída ao produto como regressão.
- [Homelab shell passou integralmente](homelab.txt), com Docker externo stub exit127 e fixtures internas. Inclui writer SQLite real; não pulou teste por ausência de sqlite3.
- [Cinco provas independentes](probes.json), executáveis com `python reports/review-r0-r1-2026-09-07/probe.py`. Ambiente por allowlist, HOME/XDG descartáveis, Compose e serviços simulados. Asserts provam lacunas residuais; não são testes de aceite para depois da correção.
- Afirmação “cp falho em qualquer posição” excede cobertura adicionada: teste novo fixa destino vaultwarden_data; há teste separado de rollback falho, mas não matriz de cp em todas as posições. Adicionar parametrização incluindo primeiro/intermediário/último volume e erro no wipe/rollback/staging.
- Sem CI nova, PR, release, instalação em host limpo ou testes físicos nesta revisão. Worktree do agente permaneceu limpa; nenhum código de produto alterado.

## Ordem recomendada

1. R01-001 antes de considerar restore liberado; provar falha real de Compose propagada.
2. R01-002 e R01-003 antes de encerrar onboarding.
3. R01-004/005 antes de fechar classificação de backup.
4. Em seguida R2 primeiro acesso, R3 gráficos herméticos e R4 UI. Não classificar toda REV-011/012/013/016 como bloqueada por operador: implementação transacional, contador de reparo, manifesto Dev e migração de adapter podem avançar em fixture; hardware/credenciais bloqueiam a certificação correspondente.
5. CI por SHA quando integração chegar à fase prevista; nenhum verified/released por relato narrativo.

## Handoff

```text
Objetivo da sessão: verificar retorno R0/R1 do agente.
Fase/IDs assumidos: contrarrevisão; R01-001..005 relacionados a REV-001..007/018.
Branch e worktree: codex/review-r0-r1; /mnt/sdcard/Projects/pz-review-r0-r1.
HEAD inicial: a82e2cc.
HEAD final: commit documental desta revisão, consultar git log.
Arquivos alterados: reports/review-r0-r1-2026-09-07; notas Estado vivo/Ledger Homelab; nota no roadmap REV.
Commits criados: documentação/evidências apenas.
Testes executados e resultados: 78 pytest; Homelab shell verde com daemon externo bloqueado; cinco provas de defeitos.
CI/PR: não criados; nenhum aceite de release.
Estado do host antes/depois: inalterado; somente fixtures/arquivos de revisão.
Segredos verificados como ausentes: ambiente por allowlist; fixtures sintéticas e diff revisto; gitleaks não executado.
Limitações e riscos restantes: P0 stop/restore; callback tardio; seleção/consistência incompletas; sem prova física.
Bloqueios reais: não houve bloqueio para revisar; certificação física permanece fase separada.
Próximo passo exato: R01-001, propagação explícita de falha em cmd_down + teste via cmd_restore real.
```
