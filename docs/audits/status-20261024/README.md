# PhaseZero — auditoria de estado em 2026-10-24

Base: `main` remoto e clone limpo em `source/PhaseZero`, SHA `ddadd6de4fc5a0b8933c2d312e2f8a6dd7f1aff3`. A release `v1.22.11` aponta ao mesmo commit, é **beta** e está instalada neste host como `phasezero-control-center 1.22.11-1`. A última release GitHub marcada estável é `v1.21.1`.

## Veredito

**Base útil, portfólio ainda não concluído.** Código publicado, pacote multiformato e CI principal existem; jornadas Desenvolvimento/Contas/Aplicativos têm estrutura comum. A própria release abre os gates PXA G2 (Windows limpo), G3 (conta/sessão/cota reais e grants por requisição) e G4 (usabilidade). Não chamar todos os apps, proxies, ChatGPT com ferramentas, Homelab remoto ou Windows VM de prontos para qualquer host limpo.

## Provas desta auditoria

- `git ls-remote` e GitHub: `main` `ddadd6d`; release beta `v1.22.11`; 11 PRs abertos. CI/gitleaks do SHA principal verdes. PR #115 conflitante; PR #63 com duas falhas `python-test`. PRs #114→#116, #117→#122 e #126→#127 são pilhas por ancestralidade, sem merge.
- Clone limpo `main`: 157 testes focados passaram (`test_product_inventory`, `test_accounts_page`, `test_windows_vm_ui`, `test_homelab_player`, `test_ai_session_ui`) em HOME/XDG temporários. Teste funcional vivo de conta, VM, appliance e inferência não foi executado.
- Host: sete serviços `phasezero-*` ativos. `pz ai routing status --json`: gateway `health:true`, mas disponibilidade dos providers `degraded` (2 ready, 12 unavailable, 16 total). Saúde do gateway não demonstra capacidade de inferência de cada conta. `pz windows-vm status --json`: blocked, disco e OVMF ausentes; guest local foi descartado conforme decisão do operador. Não houve reboot/KDE logout.
- Bonsai: npm `@bonsai-ai/cli/latest` ainda HTTP 404; controle npm HTTP 200. A tela de autenticação do fornecedor exibiu “Authentication is disabled for this application” em 2026-10-20; não houve nova tentativa de login nesta auditoria.
- `pz ai help` e `pz ai --help` retornaram `unknown ai subcommand`; sem argumento, ajuda parcial com erro. `README.md` aponta `/releases/latest`, que seleciona a release estável 1.21.1, embora host e documentação de continuidade tratem a beta 1.22.11.
- Resgate no cartão: 18 HEADs/patches/untracked atuais conferidos contra `checks/wip-manifest.json`; hashes em `checks/SHA256SUMS` verificados. É uma cópia no **mesmo cartão**, sem redundância física. Trabalho local Bonsai/WinVM ainda não está publicado. Pacote/serviços/configuração PhaseZero ainda existem no NVMe, portanto limpeza pré-formatação segue parcial.

## Capturas da UI

Todas geradas do SHA principal, em Xvfb 1280×800, tema escuro, HOME/XDG isolados. A captura ocorre ~900 ms após abrir; estados “Verificando” são transitórios. Sem conta real, clique destrutivo, leitor de tela ou prova de fluxo completo.

| Passo | Captura | Saúde | Observação |
|---|---|---|---|
| 1. Buscar app | [01-aplicativos.png](01-aplicativos.png) | Parcial | Um detalhe por app e busca existem. Lista inicial mistura `.NET SDK`, `9Router`, `ai-memory` com IDs técnicos; comparação desabilitada sem orientação de escolha. |
| 2. Preparar IA | [02-ia-dev.png](02-ia-dev.png) | Parcial | Mesmo shell visual; primeiro viewport distribui OpenCode, Claude, MCPs e agentes, com Bonsai abaixo. Serviços, contas, permissões e ferramentas ficam em telas diferentes. |
| 3. Gerir contas | [03-contas.png](03-contas.png) | Parcial | Privacidade e ausência de prova são explicadas. Estado vazio oferece “Adicionar conexão” e “Armazenar chave de API” sem sugerir qual usar para um objetivo; avatar/cota reais não avaliáveis. |
| 4. Preparar desenvolvimento | [04-desenvolvimento.png](04-desenvolvimento.png) | Boa base | Objetivo e editor opcional estão claros. Três CTAs visuais equivalentes enfraquecem a hierarquia; somente “Revisar plano e preparar” inicia a jornada. |
| 5. Windows VM | [05-windows-vm.png](05-windows-vm.png) | Parcial | Instalar/Iniciar separados; ação indisponível durante verificação. Boot direto, gráfico, resolução, TPM e guest utilizável exigem gate físico. |

## Lacunas prioritárias e aceite

1. **P0 — preservação e publicação:** revisar WIP de Bonsai e WinVM, guardar commits em PRs próprios após revisão de segredos, registrar artefatos não essenciais fora do diretório canônico; antes de formatar, decidir desligamento dos sete serviços e remoção do pacote/dados do NVMe. Para risco de falha do cartão, criar segunda cópia verificada em mídia independente. O resgate atual evita perda por formatação **apenas se SD não for apagado**.
2. **P0 — IA/contas:** fechar PXA-006/008/009 com conta/sessão/cota reais, vínculo grant→consumidor→requisição e ausência de fallback pago; deixar bloqueio explícito enquanto não houver enforcement. Distinguir provider disponível de gateway saudável. Bonsai depende de autenticação/CLI oficiais do fornecedor; não simular êxito.
3. **P0 — Windows VM:** revisar e integrar #114 antes de #116, mais WIP `winvm-integrity-sparse` em PR independente. Certificar guest limpo e primeiro boot, TPM/OVMF, rede/QGA, boot direto, resolução no monitor e fallback gráfico com evidência real. Guest deste host não existe mais.
4. **P1 — ChatGPT/DeepSeek:** integrar #117 antes de #122; prova histórica de chamada MCP privada de leitura/escrita existe, mas substituição, permissão, reboot e Windows seguem sem aceite; Full não está comprovado. #126 precede #127, que permanece Experimental sem conta real ou inferência paga.
5. **P1 — Homelab:** fechar PZ-AUD-009/010/013 com backup restaurável, consistência banco↔anexos, primeiro SSH guiado e segundo host limpo. Testes descartáveis/CI não substituem uso de appliance real.
6. **P1 — experiência:** jornada por objetivo atravessando Aplicativos→Desenvolvimento→IA→Contas, com ação principal única, status funcional e próximos passos. Provar 800×600/1280×800, escala 100/150/200%, teclado/touch/leitor de tela e G4 com participantes. Não inferir acessibilidade de captura.
7. **P1 — entrega:** resolver #115 (conflito documental) e #63 (CI vermelho e decisão explícita sobre permissão automática), alinhar README/canal stable vs beta, `pz ai help` e roadmaps com SHA atual. Só promover release estável após gates aplicáveis.

Esta auditoria não altera código, serviço, conta, boot nem VM. Screenshots e hashes são evidência local, não certificação geral.
