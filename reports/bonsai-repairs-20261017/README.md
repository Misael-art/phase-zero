# Bonsai e reparos sob demanda — evidência 2026-10-17

## Matriz de aceite

| Requisito | Prova | Estado/limite |
|---|---|---|
| Worktree dedicado, WIP preservado | `codex/bonsai-repairs`, base `fa91c09`, `/mnt/sdcard/Projects/pz-bonsai-repairs`; checkout principal `docs/handoff-20261013` intacto | verificado |
| Comparar implementações | runtime `/usr/lib/phasezero` SHA256 `9a581f48a5fd8e079b67b1dba59c55e791094cbecd970e2018730750d3b45942`; gerenciador efetivo em `~/.local/share/cc-installer/tools/phasezero-claude-manager`, SHA256 `98cd7718a42b1b54c6ab51334774ba05824bd420091cd9c8a6e758c207ec81b3` | pacote host `1.22.5-1`; runtime versionado tem detector de runner forjado, gerenciador local usa fail-open. Nenhum runner forjado importado |
| Resolução Bash | teste Bash interativo após repair, idempotência e wrapper absoluto | fixture verificada; aplicação ao host pendente pacote publicado |
| Atalho Bonsai | `phasezero-ai-bonsai` aponta ao mesmo `linux/pz` dos wrappers; desktop gerenciado passa a diagnóstico, sem rota 9Router implícita | testes; migração host pendente |
| npm 404/timeout/JSON inválido | testes `test_update_registry_failures...`; host `bonsai-status` observou HTTP 404 e versão local 0.4.19 sem executar CLI | verificado; nenhuma versão latest inventada |
| Provedor desativado | host `bonsai-probe` às 21:42:17 -03 retornou `upstream-auth-disabled`, HTTP 200 | verificado; nenhum código/URL de dispositivo publicado |
| Credencial vencida | host `credentialStatus.state=expired-refresh-required`, authenticated=false; fixture cifrada no formato upstream | verificado; conteúdo nunca emitido |
| Login falha claramente | host `login bonsai` retornou 1, “Login indisponível no provedor”, antes do CLI; testes impedem criação de processo e verificam bytes preservados | recuperação/login bem-sucedido dependem do Bonsai |
| Sessão e proxy distintos | `sessionUsable=false`, `proxyAvailable=false`, gate `official-api-auth-contract-unverified` | indisponíveis; não são login funcional |
| UI pública | PySide6 na sessão real XCB/KDE, tema claro/escuro, janela MainWindow 800×600 lógicos, página 748 px, scroll horizontal máximo 0 | capturas anexas; controles impossíveis desabilitados; detalhe técnico recolhido |
| Não iniciar inferência | status lê package.json/metadados locais e registry; login só autenticação após gates; start gerenciado bloqueado | testes; nenhuma inferência iniciada |
| Microfone | `PZ_REPAIR_NONINTERACTIVE=1 python3 linux/repairs/manager.py run microfone --yes` exit 0; perfil `HiFi (Mic, Speaker)`, fonte `mic-biglinux` | presença real verificada; áudio não gravado, sinal acústico não comprovado |
| Entrada | Nova execução `timeout 55 python3 linux/repairs/manager.py run entrada --yes` exit 0: barramento ativo, nós presentes | execução real comprovada; operador não consegue testar agora, resposta física de toque/trackpads pendente |
| Atalhos padrão reparos | instalação de usuário, primeira abertura da UI e convenience-launchers criam desktop/menu, sem executar reparos; confirmação em cada execução | testes isolados; migração do host pendente pacote |

## Contrato Bonsai e consentimento

Referências oficiais investigadas: https://www.trybons.ai e https://www.trybons.ai/terms.
Consulta pública retornou 502; curl no host falhou resolução DNS nessa consulta.
Não foi comprovado contrato oficial de API de inferência/autenticação para outros
CLIs. Resultados de outros produtos homônimos e projetos de engenharia reversa
não constituem contrato oficial e não foram usados como adapters.

Proxy permanece indisponível. Desbloqueio exige documentação oficial versionada,
método de autenticação suportado, adapter isolado, loopback, autenticação local,
grant aplicado por consumidor/projeto, ausência de fallback, desligamento e rollback,
mais teste real consentido. Nenhum token de sessão vira chave genérica.

`bonsai start` avisa possibilidade de acessar/enviar dados do workspace e aponta
termos; exige `--cwd` explícito. Continua bloqueado antes de processo por ausência
de grant verificável. Qualquer implementação futura também deve recolher
consentimento por execução, vinculado ao diretório escolhido; consentimento de
login não autoriza inferência. Nenhum início implícito por login/status/atalho.

## Operação e reversão

Após pacote publicado e instalado, executar `pz ai claude repair-bonsai` para
normalizar wrappers, desktop e bloco PATH no fim dos perfis existentes. Não instala
CLI nem reinicia serviço. Manifesto transacional devolvido permite
`pz ai claude rollback <manifest>`. Reabrir shell ou `source ~/.bashrc` e `hash -r`;
nenhum logout KDE necessário. A UI usa o gerenciador do próprio runtime instalado.

`pz repair install` cria atalhos sob demanda. `pz repair status` só observa
pré-requisitos. `pz repair run microfone --confirm` e `pz repair run entrada --confirm`
exigem confirmação gráfica. Modo terminal: `--yes`. Entrada ainda usa ponte
administrativa explícita; nunca senha armazenada ou sudo sem senha. Nenhum timer,
serviço permanente, reboot ou encerramento de sessão. Captura de microfone só com
`PZ_REPAIR_RECORD_CONSENT=1`; gravação temporária removida ao sair.

Scripts originais fornecidos pelo operador foram incorporados ao repositório;
reparo de entrada agora usa heredoc-free root helper com argumentos fixos,
sem expansão prematura de variáveis e sem ciclo USB genérico. Atalhos existentes
não gerenciados são preservados; duplicatas legadas do host precisam migração
com backup após instalação aprovada do pacote, sem sobrescrever WIP alheio.

## Handoff

Objetivo: Bonsai honesto e reparos sob demanda integrados.
Fase/IDs: Bonsai/provider/command/UI; pacote/release gate herdado do roadmap.
Branch/worktree: codex/bonsai-repairs, diretório dedicado acima.
HEAD inicial: fa91c09. HEAD final/commits/CI: consultar Git/PR desta branch.
Arquivos: gerenciador Claude/Bonsai, registro auth, páginas IA, catálogo/inventário,
manager/scripts repairs, pz, instalador usuário e atalhos, testes.
Testes: baseline Claude 21 passed/15 subtests; suíte focada final 109 passed/17
subtests; shell Claude 34 testes OK; ShellCheck com excludes do CI; diff-check.
Host antes/depois: pacote 1.22.5-1 mantido, sem deploy manual em /usr/lib; sem
inferência, reboot, logout KDE ou alteração de workloads Homelab.
Segredos: sem valores em saída/relatório; fixtures artificiais.
Limites: login/proxy externos bloqueados; entrada depende autorização OS e teste
físico; sinal de microfone exige consentimento específico.
Próximo passo: CI verde, concluir teste entrada autorizado, merge e release canônica;
instalar pacote verificado e migrar wrappers/atalhos, preservando backups.

Revisão final: timeouts e respostas inválidas do provedor/registry têm classes
separadas. stdout/stderr do CLI de login são descartados para impedir códigos de
dispositivo em logs da UI; erro público continua acionável, com restauração de
credencial em falha. Perfil de microfone só é escolhido entre perfis de captura
observados e disponíveis (quatro testes próprios, novo teste de recusa sem captura).
Nenhuma versão do pacote ou tag foi alterada. CI integral permanece gate externo;
execução local integral anterior foi interrompida após ficar obsoleta pelas correções
e ter reproduzido expectativa antiga de uma única sonda na página IA & Dev.
Teste de lifecycle atualizado comprova duas sondas somente ao abrir a página.

Continuação: teste de entrada autorizado e executado, exit 0, sem reboot/logout. Operador informou não poder testar resposta física agora. CI anterior revelou timeout no restyle global do teste UI e SC2015 no ShellCheck 0.9; teste temático foi isolado em subprocesso com MainWindow 800×600 e clique público do modo avançado, guard de entrada reescrito com if explícito.

## Revisão posterior e limites do diagnóstico

Revisão do PR identificou que a sondagem WorkOS criava tentativas de login
órfãs. Essa sondagem foi removida. Diagnóstico atual não faz POST de autorização,
não visita URL de dispositivo e não segue redirects de autenticação. Preserva a
observação histórica `upstream-auth-disabled` com origem/data, marca cache após
15 minutos como antigo e disponibilidade atual como desconhecida. Sem contrato
oficial de disponibilidade passiva, login permanece indisponível; atualizar
diagnóstico não promete revalidar login. Recuperação depende de canal suportado
pelo Bonsai. Cache de provedor não recebe escritores automáticos, eliminando
substituição concorrente de resultado novo por antigo.

Status não depende mais da rede: registry só atualiza no diagnóstico explícito;
resultado de npm cacheado tem validade de 15 minutos. Registry codificado
`https://registry.npmjs.org/@bonsai-ai%2Fcli/latest` também retornou HTTP 404 no
host. Nenhuma versão inventada. CLI instalado continua 0.4.19.

Fluxo interativo futuro, quando gates externos permitirem, usa terminal privado
`/dev/tty` para instruções, nunca stdout/stderr do ledger da UI. Sem terminal,
falha com próximo passo explícito. Não foi executado com provedor desativado.
Atalhos rejeitam symlinks, usam substituição atômica e instalação idempotente
preserva bytes/mtime; testes adicionados. Wrapper sem argumentos já retorna pelo
case `status` com exec antes de shift; revisão que alegou shift sem args não se
aplica ao fluxo atual.
