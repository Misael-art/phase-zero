# Diagnóstico e plano de paridade Windows/Linux

Data: 2026-10-19, America/Sao_Paulo. Autor: Codex.
Estado: diagnóstico estático e plano; implementação e instalação pendentes.
Solicitação: instalar futuramente o PhaseZero no Windows guest e aproximar suas
funções, configurações e UI do Linux hospedeiro. Nesta entrega, somente registrar,
commitar e publicar o diagnóstico. Nenhuma aprovação de requisitos físicos decorre
da publicação deste documento.

## Escopo e fontes

Repositório acessado pelo guest em
`\\10.0.2.4\qemu\sdcard\Projects\PhaseZero`.
Foram examinados README, version.json, bootstrap Windows, CLI, perfis, catálogo e
registro de páginas Linux, workflows, integração do guest e handoff de outubro.
Referências obrigatórias para execução futura:

- [WinVM Boot Resilience](../roadmaps/winvm-boot-resilience-v1.md).
- [Homelab remediation](../roadmaps/homelab-v1.15.1-remediation.md).
- [Homelab parity](../roadmaps/homelab-umbrelos-parity-v1.md).
- [Apps, desenvolvimento e contas](../roadmaps/apps-dev-ai-accounts-v1.md).
- [Handoff de outubro](../handoff/2026-10-13-session-handoff.md).
- [Superfície de mutação](../host-surface.md).

Essas fontes históricas não comprovam o estado vivo. Revalidar host, Git, CI,
release e pacote antes de implementar. Nenhuma regra Ponytail foi aplicada:
`src-tauri/Cargo.toml` identifica um pipeline experimental RetroDev Studio;
presença de Rust/Tauri não prova que seja a arquitetura do Control Center.

## Baseline observado

| Item | Observação | Limite |
|---|---|---|
| SO da sessão | Windows build 26200; máquina PHASEZE-7SVSMPQ | Edição e hardware não confirmados por CIM |
| PowerShell | 5.1.26100.9444 | Execução funcional do aplicativo não testada |
| Ferramentas | winget, OpenSSH, WSL e Pester 3.4.0 encontrados | Presença não comprova serviço ou runtime saudável |
| Versão do código | 1.22.5 beta | Não prova versão instalada |
| Checkout na leitura | docs/handoff-20261013, referência edf65d77cf29762459c2f3589f144d24410e9147 | Revalidar antes de alterações |
| Windows UI | WPF em bootstrap-ui.ps1; 12 páginas declaradas | Sem captura visual atual |
| Windows backend | bootstrap-tools.ps1, aproximadamente 37.642 linhas | Tamanho é custo de manutenção, não defeito funcional por si só |
| Windows UI/CLI | Aproximadamente 8.815/2.516 linhas | Modularização precisa preservar contratos |
| Linux UI | PySide6/Qt e páginas especializadas | Não executada nesta sessão |
| Estado local | C:\ProgramData\PhaseZero contém arquivos de provisionamento e integração | Não prova aplicativo instalado |
| Ferramentas opcionais | rtk missing; ai-memory missing na sessão | Sem consulta ou escrita de memória durável |

O handoff registra pacote Linux 1.22.5 de branch de integração, diferente do
artefato publicado com mesmo número. Comparar commit, procedência e capacidades;
não aceitar igualdade de versão como prova de paridade.

`C:\ProgramData\PhaseZero\provisioning-complete.json` registra, em
2026-09-24T05:52:48.7628151Z, QGA Running, compartilhamento
`\\10.0.2.4\qemu`, unidade P: e Microsoft Basic Display Adapter. São dados
históricos, não sondagem atual. Avisos históricos incluem pacote Xbox retido e
reparo do registro LanmanWorkstation. Revalidar sem repetir reparos cegamente.

## Achados e classificação

| ID | Prioridade | Achado/evidência | Impacto e tratamento |
|---|---|---|---|
| WLP-001 | P0 | Get-BootstrapOsInstallHostProfile classifica Steam Deck ou PC genérico; caminhos examinados não demonstram contexto QEMU adequado | Separar Windows nativo, guest, plataforma desconhecida e host remoto; testar recomendações |
| WLP-002 | P0 | UI Windows oferece EFI/BCD, partições e dual boot físico | Guest EFI não representa GRUB Linux; separar jornadas e bloquear ações incompatíveis |
| WLP-003 | P1 | README orienta bootstrap pelo checkout; packaging e release focam Linux | Distribuição Windows independente de SMB, com versão, integridade, reparo, upgrade e remoção |
| WLP-004 | P1 | safe-base JSON tem listas Windows vazias; catálogo PowerShell define ferramentas explicitamente | Não concluir perfil Windows vazio: existe catálogo separado. Unificar intenção e declarar diferenças |
| WLP-005 | P1 | ConvertTo-UiCanonicalStatus agrupa unavailable em not-installed | Falha de leitura pode parecer ausência confirmada; criar estado desconhecido e bloquear ação dependente |
| WLP-006 | P1 | Ensure-BootstrapHomelabStack retorna com WARN quando Docker não está pronto ou compose falha | Falha não é propagada diretamente pela função; reproduzir efeito no resultado global e corrigir contrato |
| WLP-007 | P1 | Provisionamento Homelab Windows mantém caminho próprio de compose/.env | Comparar catálogo, governança, backup, saúde e segredos com Linux; priorizar administração remota |
| WLP-008 | P1 | UI, catálogos, perfis e estados evoluem separadamente | Compartilhar schemas, IDs e fixtures; manter adaptadores nativos |
| WLP-009 | P1 | SMB dá acesso a arquivos, sem comprovar execução autenticada no host | Pareamento e canal explícito; identidade persistente, permissões e reconexão |
| WLP-010 | P1 | Driver/serviços atuais não confirmados; registro antigo aponta Basic Display | Verificar driver, resolução, aceleração disponível, áudio, entrada e integração |
| WLP-011 | P1 | Handoff registra vazamento anterior de testes para estado real | Testes mutáveis exigem HOME/XDG/estado isolados e verificação de paths; PZ_STATE sozinho não isola |
| WLP-012 | P2 | Backend e UI Windows extensos | Extrair módulos por responsabilidade gradualmente, sem reescrita ampla inicial |
| WLP-013 | P2 | UI mistura wizard de instalação e manutenção; nomes Bootstrap Tools permanecem | Organizar jornadas contínuas, identidade PhaseZero e alvo local/remoto explícito |
| WLP-014 | P1 | Paridade e instalação ainda sem critérios operacionais comuns | Matriz por capacidade com suporte, evidência, reversão e maturidade |

Locais principais: `bootstrap-tools.ps1` (Ensure-BootstrapHomelabStack,
Get-BootstrapOsInstallHostProfile, catálogo de perfis), `bootstrap-ui.ps1`
(Get-UiPageIds, ConvertTo-UiCanonicalStatus), `profiles/safe-base.json`,
`linux/ui_native/pages/registry.py`, `linux/ui_native/catalog.py`,
`linux/ui_native/product_inventory.py`, `.github/workflows/ci.yml` e
`.github/workflows/release.yml`. Usar símbolos, pois linhas mudam.

## Matriz de paridade pretendida

Paridade significa capacidade, clareza e recuperação equivalentes, com adaptações
por sistema. Não exige copiar comandos Linux para Windows.

| Área | Base observada | Aceite proposto Windows |
|---|---|---|
| Instalação PhaseZero | Bootstrap e checkout | Instalar, abrir, reparar, atualizar e remover sem checkout/SMB |
| Apps/dependências | Catálogo Windows amplo | Estado real, origem, versão, prévia, instalação e remoção |
| Perfis | JSON e catálogo PowerShell separados | Intenção comum e diferença explícita por plataforma |
| Configurações | Rotinas existentes nos dois sistemas | Atual/desejado, plano, aplicação, verificação e restauração |
| Diagnóstico | Doctor, drift e suporte Windows | Estados, gravidade, evidência e próximos passos consistentes |
| IA/MCP | Instalação e configuração existentes | Distinguir Windows, WSL e Linux remoto; provar comunicação |
| Contas | Central APIs Windows e modelo Linux mais amplo | Conta, conexão, grant por consumidor, expiração e revogação |
| Homelab | Docker local Windows e gestão Linux especializada | Administrar Linux sem exigir stack local duplicada |
| Serviços | Mecanismos específicos por plataforma | Saúde, start/stop, logs e recuperação com contrato comum |
| Jogos/emulação | Componentes Windows e área Linux especializada | Inventário, configuração e proteção de saves/ROMs/BIOS |
| Steam Deck | Automação Windows existente | Distinguir hardware físico de dispositivos do guest |
| Boot/sessão | Dual boot Windows e lifecycle da VM no Linux | Reiniciar/desligar guest e retornar ao Linux com semântica correta |
| Temas/acessibilidade | Interfaces distintas | Identidade comum, DPI, foco, teclado, toque e mensagens claras |
| Backup/rollback | Mecanismos em ambas as bases | Escopo, limitações e recuperação de falha parcial demonstrados |

Waydroid, systemd, GRUB e KDE pertencem ao Linux selecionado. Expor gestão remota
quando suportada. Não apresentar capacidade Linux ausente como pacote Windows
faltante. Não habilitar WSL/Hyper-V/Docker dentro do guest sem verificar suporte
de virtualização e recursos disponíveis.

## Arquitetura e contratos propostos

Topologia: Windows guest -> canal autenticado -> PhaseZero instalado no Linux ->
operação no host. O compartilhamento não é canal de administração.

- Mostrar alvo em toda ação: Este Windows, Linux hospedeiro ou outro host.
- Identidades persistentes; não usar endereço SMB como identidade do host.
- Catálogo restrito de operações remotas; não shell arbitrário por padrão.
- Pareamento, revogação, incompatibilidade de versão e desconexão explícitos.
- IDs persistentes de operação, consulta de resultado e reconexão.
- Shutdown gracioso; matar QEMU nunca é caminho normal de encerramento.
- Desligar host explicita que também termina guest e sessão atual.
- Não instalar driver AMD físico porque o hospedeiro é Steam Deck.
- Preservar gates atuais de grants por requisição; não desbloquear integrações
  apenas para aparentar paridade.

Contrato por recurso: ID, alvo, suporte, estado observado, instante/origem da
observação, estado desejado, plano, execução, verificação e reversão.
Configuração declara privilégio, paths/serviços afetados, reinício necessário,
backup e limite de rollback. Diferenciar instalado, configurado e testado.

Separar binários, configuração, estado, cache e logs. Preservar preferências e
dados pessoais em upgrades/desinstalação. Não escrever configurações Linux usando
paths inferidos do Windows só porque o código roda de SMB.

DPAPI já existe no backend Windows; preservar armazenamento apropriado ao sistema.
Exportação comum leva preferências/referências. Migração de segredo exige fluxo
próprio; não copiar segredos ou sessões automaticamente entre consumidores/hosts.

## UI e jornadas propostas

Windows declara health, welcome, selection, host-setup, app-tuning, ai-tools,
api-center, api-catalog, steamdeck-control, dual-boot, review e run.
Linux possui áreas especializadas adicionais, incluindo Homelab, Desenvolvimento,
Contas, Emulação, Temas e Windows VM. Isso indica diferença estrutural, não prova
defeito visual de layout.

| Área proposta | Jornada |
|---|---|
| Início | Saúde, pendências, alvo ativo e ações principais |
| Aplicativos | Instalar, configurar, atualizar e remover |
| Desenvolvimento | Ambientes de projeto e ferramentas |
| IA | Runtimes, agentes, MCP e roteamento |
| Contas/conexões | Login, escopos, consumidores e revogação |
| Homelab | Hosts, apps, serviços, backups e logs |
| Sistema | Ajustes compatíveis com alvo selecionado |
| Integração VM | Tela, dispositivos, compartilhamento e retorno ao Linux |
| Histórico | Planos, operações, falhas e restauração |

Priorizar alvo antes da ação e tornar seleção múltipla inequívoca. Evitar exigir
modo avançado para recuperar falha comum. Primeira etapa não é reescrever WPF ou
Qt: estabilizar contratos e depois aproximar navegação/apresentação.

Validação visual pendente: 1280x800, monitor externo, escalas 100/125/150/200%,
teclado, foco, toque, leitor de tela, textos longos, loading, erro e indisponível.
Sem capturas atuais não há auditoria visual nem conformidade de acessibilidade
comprovada. Skill Product Design audit exige captura do fluxo; não foi possível
capturar app nativo na sessão original. Avaliação acima é estrutural.

## Plano por fases e gates

| Fase | Entrega | Gate |
|---|---|---|
| 0 | Inventário Windows/Linux, pacote, commit, drivers, serviços, recursos e procedência | Baseline com fonte/data e lacunas nomeadas |
| 1 | Contexto guest/nativo/remoto e guardas de boot/discos/drivers | Cenários incompatíveis bloqueados em testes |
| 2 | Schemas comuns de capacidade, estado, plano, operação e erro | Fixtures compartilhadas aceitas pelos adaptadores |
| 3 | Artefato Windows, atalhos, CLI, repair/upgrade/uninstall | Instalação e abertura sem checkout ou SMB |
| 4 | Apps, perfis, ajustes, doctor e rollback harmonizados | Idempotência e recuperação de falha parcial |
| 5 | Pareamento/gestão Linux, consulta e reconexão | Windows administra host de teste sem stack local |
| 6 | IA/contas Windows, WSL e remoto | Teste por consumidor, revogação e gates preservados |
| 7 | Jornadas/UI alinhadas | Fluxos completos e QA visual representativa |
| 8 | Validação real VM: display, entrada, arquivos, shutdown e retorno | Evidências ligadas aos IDs WBR; sem declarar verified por mock |
| 9 | CI, release, checksums, instalação e recuperação | Procedência rastreável e critérios operacionais satisfeitos |

Dependência: 0 -> 1 -> 2. Distribuição e ponte remota podem avançar em paralelo
depois disso. Polimento final depende dos contratos. Não instalar full-workstation
antes de dimensionar guest e verificar compatibilidade.

Cada ID deve manter estado planejado/implementado/verificado/bloqueado, arquivos,
teste e prova real. Este documento não substitui matrizes WBR/Homelab/PXA.
Implementação futura deve usar worktree próprio e preservar WIP alheio.

## Testes exigidos para implementação

- Windows físico, QEMU e contexto desconhecido; host offline/incompatível.
- Usuário comum; elevação aceita, recusada e interrompida.
- Paths locais/UNC, espaços, português e compartilhamento indisponível.
- Winget ausente/ocupado, pacote incompleto, timeout e reinício pendente.
- Estado ilegível como desconhecido, sem conversão otimista.
- Reaplicação idempotente e falha parcial recuperável.
- Identidade remota divergente, perda de conexão e consulta posterior do resultado.
- Conta revogada bloqueando consumidor; nenhuma exportação automática de sessão.
- Upgrade preserva configuração; uninstall preserva dados pessoais.
- Shutdown real limpo; display/áudio/entrada e integração verificados no guest.
- Testes mutáveis em HOME/XDG isolados: uma atribuição por variável; verificar
  paths antes de operações destrutivas. Nunca atingir containers/VM/GRUB reais.

CI Windows existente inclui Pester, parsing e fixtures de Credential Manager/DPAPI.
Não inferir resultado atual do workflow pela existência do YAML.

## Verificações efetivamente realizadas

Parsing em memória com Parser.ParseInput, lendo UTF-8 no PowerShell 5.1:

| Script | Erros sintáticos |
|---|---|
| bootstrap-tools.ps1 | 0 |
| bootstrap-ui.ps1 | 0 |
| install-cli.ps1 | 0 |
| Setup-AITools.ps1 | 0 |
| linux/windows-vm/guest-login.ps1 | 0 |
| linux/windows-vm/qga-offline-repair.ps1 | 0 |

Tentativa inicial ParseFile via UNC falhou na leitura; não era erro sintático dos
scripts. ParseInput corrigiu o método de verificação. Leitura de arquivos e
metadados locais não comprova execução funcional.

Não executados: instalação, bootstrap UI, suíte Pester completa, CI remoto,
sondagem operacional Linux, boot físico e QA visual. Na sessão original read-only,
SCM/CIM foram bloqueados; serviços, RAM, GPU e resolução atuais não confirmados.
Nenhuma evidência histórica de armazenamento/Btrfs ou boot foi encerrada aqui.

## Handoff

Objetivo da sessão: registrar diagnóstico e plano para retomada posterior.
Fase/IDs assumidos: diagnóstico WLP-001..014; implementação pendente.
Branch e worktree: checkout compartilhado docs/handoff-20261013; conferir no commit.
HEAD inicial: referência observada edf65d77cf29762459c2f3589f144d24410e9147.
HEAD final: commit documental que contém este arquivo; consultar git log pelo path.
Arquivos alterados: somente este documento, salvo registro explícito posterior.
Commits criados: commit documental; hash e push reportados na conclusão da sessão.
Testes executados e resultados: seis parsings sem erros; validação documental no commit.
CI/PR: sem alegação de CI verde; nenhum PR solicitado.
Estado do host antes/depois: diagnóstico não alterou aplicação, serviços, guest,
Linux, GRUB, discos, configurações ou workloads. Ferramentas locais de Git podem
ser preparadas para cumprir publicação documental; isso não instala PhaseZero.
Segredos verificados como ausentes: documento não contém credenciais; não foi
executada varredura abrangente de segredos do repositório.
Limitações e riscos restantes: paridade, runtime vivo, distribuição e UI física
não verificados; achados estáticos não equivalem a reprodução ponta a ponta.
Bloqueios reais: consultas SCM/CIM e captura visual indisponíveis no diagnóstico;
instalação e execução fora do escopo desta entrega documental.
Próximo passo exato: revalidar Git e pacotes, fechar baseline dos dois sistemas,
corrigir contexto guest/host e estados ambíguos, então preparar distribuição
Windows mínima independente do compartilhamento.
