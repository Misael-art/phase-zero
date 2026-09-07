# Revisão independente — remediação, Windows VM e experiência de uso

Base revisada: `codex/aud-fase5`, `9d6be9d` (inclui fases 0–4). `origin/main` continua `2180c94`; pacote instalado `1.19.0-1`. Nenhuma alteração de produto nesta revisão.

**Parecer: trabalho útil, conclusão não aceita.** Há correções reais, mas P0 de restore persiste, onboarding quebra no stdout real, contrato de boot gráfico é incompatível e aceites clean-host/Windows/hardware permanecem abertos. Não aprovar lançamento como portfólio totalmente automatizado e resiliente.

## Achados acionáveis

Fila estruturada: [backlog.json](backlog.json). Prioridade P0 bloqueia dados/restore; P1 bloqueia a promessa correspondente; P2 melhora descoberta/usabilidade. Provas reproduzidas usam fixtures, sem workloads reais.

### REV-001 — P0 — Restore perde volume parcialmente copiado

Fonte: [linux/server/homelab-stack.sh:1205](../../linux/server/homelab-stack.sh#L1205). Relacionado: PZ-AUD-010.

O wipe precede cp; applied recebe o volume só após sucesso. Falha de cp deixa o destino vazio/parcial fora do rollback, que reporta rollbackApplied:true. Reproduzido com arquivo original eliminado e cp exit 42.

Trabalho: Registrar volume antes da primeira mutação; rollback incluir volume falho; falha de rollback bloquear conclusão.

Aceite: Injetar ENOSPC/erro de cp após wipe em cada posição; todos os bytes anteriores restaurados ou estado recovery-required verdadeiro.

### REV-002 — P1 — Backup SQLite não é snapshot vivo consistente

Fonte: [linux/server/homelab-stack.sh:841](../../linux/server/homelab-stack.sh#L841). Relacionado: PZ-AUD-009.

cp -a copia base/WAL/SHM enquanto escritor pode alterá-los; .backup é executado na cópia já capturada, não no banco vivo. Consistência entre banco e anexos não é provada; Prometheus sem marcadores SQL pode receber consistent:true.

Trabalho: Usar API SQLite na origem com contrato por app; dumps nativos ou parada/quiesce para servidores; snapshot coordenado dos anexos.

Aceite: Escritor concorrente + checkpoints WAL + restore + integrity_check e invariantes de aplicação; classificar desconhecido como não certificado.

### REV-003 — P1 — Pré-restore captura dados antes de parar serviços

Fonte: [linux/server/homelab-stack.sh:1143](../../linux/server/homelab-stack.sh#L1143). Relacionado: PZ-AUD-010.

Snapshot tar para rollback ocorre antes de cmd_down (1163); rollback pode recolocar banco inconsistente mesmo quando cópia funciona.

Trabalho: Parar/quiescer e confirmar ausência de escritores antes do snapshot; preservar estado anterior de execução.

Aceite: Banco sob escrita, restauração falha, rollback íntegro e retorno ao estado anterior.

### REV-004 — P1 — Onboarding rejeita JSON válido da CLI

Fonte: [linux/ui_native/pages/homelab.py:374](../../linux/ui_native/pages/homelab.py#L374). Relacionado: PZ-AUD-013.

_first_json_line tenta json.loads por linha. prepare --dry-run real usa jq -n multilinha: exit 0 e objeto válido viram {} no Player. Reproduzido sem daemon.

Trabalho: Parser único do documento/envelope completo; stderr separado; validar schema.

Aceite: Alimentar QProcess com stdout real de prepare/discover/pair em chunks e pretty/compact; plano aparece.

### REV-005 — P1 — Pareamento falho permite avançar

Fonte: [linux/ui_native/pages/homelab.py:348](../../linux/ui_native/pages/homelab.py#L348). Relacionado: PZ-AUD-013.

Condição testa ausência da chave pair. Após pair=false, novo Avançar pula para profile. Reproduzido.

Trabalho: Exigir pair is True para host atual, manter erro acionável e retry.

Aceite: False/cancel/offline não avançam; só sucesso do mesmo host libera.

### REV-006 — P1 — Confirmação de plano sobrevive à troca de host

Fonte: [linux/ui_native/pages/homelab.py:441](../../linux/ui_native/pages/homelab.py#L441). Relacionado: PZ-AUD-013.

_on_host_changed não invalida review_plan/pair/confirmed; JSON de prepare não inclui identidade do host. Plano idêntico em B reaproveita aceite de A. Callback também lê seleção mutável. Reproduzido com payload compacto para isolar defeito do parser.

Trabalho: Capturar hostId + perfil + apps + revisão + operação; invalidar ao trocar destino; backend conferir token.

Aceite: Revisar A, selecionar B, receber callback atrasado de A: nenhuma mutação em B sem nova revisão.

### REV-007 — P1 — Perfil escolhido não dirige preparo

Fonte: [linux/ui_native/pages/homelab.py:408](../../linux/ui_native/pages/homelab.py#L408). Relacionado: PZ-AUD-013.

profile é guardado em _onboard_state, mas prepare recebe somente --dry-run/--json e execução só --json. Backend usa apps default; não consome seleção de onboarding.

Trabalho: Transmitir perfil/apps/acesso no plano tipado, depois aplicar exatamente esse plano.

Aceite: Duas seleções distintas geram conjuntos distintos; apps não escolhidos permanecem desligados.

### REV-008 — P1 — Primeiro SSH ainda exige terminal

Fonte: [linux/server/homelab-hosts.sh:526](../../linux/server/homelab-hosts.sh#L526). Relacionado: PZ-AUD-014.

Porta/chave foram melhoradas, mas first-contact orienta ssh-copy-id manual; BatchMode=yes continua sem autenticação inicial interativa. Parear não completa jornada leiga em host novo.

Trabalho: Fluxo de primeira confiança + autenticação protegido na UI/terminal embutido; timeout/cancel; chave sem senha apenas com decisão informada.

Aceite: Admin sem chave + appliance novo + porta customizada: parear sem terminal externo, senha fora de argv/log.

### REV-009 — P1 — Boot automático e launcher discordam sobre experimental

Fonte: [linux/windows-vm/windows-vm-session.sh:415](../../linux/windows-vm/windows-vm-session.sh#L415). Relacionado: WBR-005.

Probe elegível produz --graphics virtio-gl, sem --experimental; launcher guard (windows-vm.sh:2174) rejeita perfil explícito. Funções reais extraídas reproduzem rc 1 antes do launch. Domínio libvirt ainda impõe outro bloqueio.

Trabalho: Unificar escolha/consentimento/backend em contrato; passar flags coerentes somente quando autorizado; compat funcional explícito.

Aceite: Sessão real com launcher real e QEMU stub aceita plano elegível; sem consentimento seleciona compat diretamente; ramo libvirt coberto.

### REV-010 — P1 — Maturidade gráfica e indicador de aceleração contraditórios

Fonte: [linux/windows-vm/graphics-profiles.json:21](../../linux/windows-vm/graphics-profiles.json#L21). Relacionado: WBR-005.

JSON chama virtio-gl stable e label aceleração OpenGL; graphics.sh:656 marca experimental e não garante 3D Windows. UI windows_vm.py:435 habilita toggle pela presença de QEMU e marca ligado por perfil != compat.

Trabalho: Uma fonte de maturidade; separar render host, driver guest e API 3D comprovada; experimental em opt-in avançado.

Aceite: Host GL disponível/guest sem 3D nunca exibe aceleração validada; contrato UI/CLI/provision/session idêntico.

### REV-011 — P1 — Runtime instalado diverge do pacote

Fonte: [docs/roadmaps/winvm-boot-resilience-v1.md:69](../../docs/roadmaps/winvm-boot-resilience-v1.md#L69). Relacionado: WBR-004.

Leitura de host: pacote 1.19.0-1; provenance do boot 1.16.6 de 20/08; marker pending existe. Não foi refeito runtime nem boot.

Trabalho: Sincronização transacional a partir do pacote com preview/elevação; validar hash antes de próxima sessão e orientar atualização pendente.

Aceite: Upgrade real em VM descartável, current após sync; LCD e monitor no runtime entregue; rollback do runtime testado.

### REV-012 — P1 — Resiliência física e recuperação continuam sem aceite

Fonte: [docs/roadmaps/winvm-boot-resilience-v1.md:72](../../docs/roadmaps/winvm-boot-resilience-v1.md#L72). Relacionado: WBR-001..008.

WBR-007 não implementa contador repairFailed>=2; WBR-001/003/005/006 exigem provas físicas. Registro de csum/aio de agosto permanece sem evidência de encerramento; não implica erro ativo hoje. Retry compat não repete teste stable imediatamente após segundo launcher (session:611).

Trabalho: Encerrar investigação de armazenamento com operador; implementar recuperação guiada e trava pós-guest-start/crash também no fallback.

Aceite: Boot frio, desligamento QGA indisponível, crash tardio no fallback, reparo sem interrupção, 2 falhas escaladas, LCD/dock documentados.

### REV-013 — P1 — Ambiente de desenvolvimento Windows não certificado

Fonte: [linux/windows-vm/windows-vm.sh:1893](../../linux/windows-vm/windows-vm.sh#L1893). Relacionado: novo.

CPU host/KVM e canais QGA/RDP/arquivos existem; não há matriz de instalação/build/debug/reboot nem gate nested/WSL2 no subsistema. Host mostra nested=1, insuficiente para provar exposição e funcionamento no guest.

Trabalho: Perfil Windows Desenvolvimento separado: ferramentas comuns, disco/RAM, dependências, retomada, backup e smoke real; WSL2/Docker opção condicional.

Aceite: Guest limpo instala toolchain, clona fixture pública, build/test/debug, reinicia e retoma; nested confirmado no guest antes de WSL2; GPU testada por API/carga.

### REV-014 — P1 — Homelab corta controles no modo simples

Fonte: [linux/ui_native/pages/homelab.py:111](../../linux/ui_native/pages/homelab.py#L111). Relacionado: PZ-AUD-029.

Render offscreen 1280x800 mostra caixas Primeiros passos/Perfil/Ações comprimidas e botões parcialmente cortados. Página contém grupos empilhados e tabela expansível sem scroll global; não é somente falta de dados.

Trabalho: Página rolável e responsiva; modo simples com estado, ação principal e etapas legíveis; tabela/log/política em avançado.

Aceite: Screenshots + geometria asseguram controles completos em 1280x800, 800x600 e escala 150/200%; teclado/touch utilizáveis.

### REV-015 — P2 — Objetivos adicionados sem substituir jornadas técnicas

Fonte: [linux/ui_native/pages/dashboard.py:33](../../linux/ui_native/pages/dashboard.py#L33). Relacionado: PZ-AUD-029.

Início mantém onboarding IA universal, ações rápidas e ferramentas, além dos 5 objetivos; 20 categorias de sidebar. Cuidar de outro computador executa hosts list JSON; Jogos, Android e VM executa profile.gaming, sem instalar VM/Android.

Trabalho: Objetivos abrem assistente específico, com plataforma/destino e opções relevantes; primeiros passos por objetivo; detalhes técnicos só no avançado.

Aceite: Usuário sem terminal conclui cada objetivo; nenhum card promete solução não entregue; teste de usabilidade sem orientação.

### REV-016 — P1 — Paridade IA ainda documenta migrações pendentes

Fonte: [assets/ai/proxy-manifest.json:40](../../assets/ai/proxy-manifest.json#L40). Relacionado: PZ-AUD-019/020/021.

Manifesto admite MiMo Windows env-session/Go versus API oficial Linux e default DeepSeek divergente. Leitor de manifesto não conclui migração nem valida conversa real. Hermes continua bloqueado.

Trabalho: Migrar adapters antes de anunciar paridade; matriz supported/experimental/blocked consumida por UI; fixtures e inferência supervisionada por plataforma.

Aceite: Windows/Arch limpos: instalar, autenticar, chat/stream/tool, expirar credencial, reiniciar e recuperar sem segredo em log.

### REV-017 — P1 — Conclusão e certificação superestimadas

Fonte: [reports/portfolio-clean-host-2026-09-06/backlog.json:24](../../reports/portfolio-clean-host-2026-09-06/backlog.json#L24). Relacionado: PZ-AUD-028.

31/31 verified com ciProof textual pendente; gh não encontra PR nova nem run fase5; main segue 2180c94. arch-clean-host configura multilib/preinstala ferramentas e só testa instalação/status/dry-run, não preparo+app+reboot.

Trabalho: Separar implementação, regressão local, CI, E2E/hardware, integração/release; reabrir aceites pendentes; publicar provas por SHA.

Aceite: PR/CI do SHA final + asset instalado em Arch e Windows limpos, app funcional e reboot; estados refletem evidência real.

### REV-018 — P1 — Gate Homelab depende do daemon

Fonte: `tests/linux-homelab.sh:961`, `linux/server/homelab-stack.sh:684`. Suite interrompe em `FAIL: refusal hides maturity` no sandbox sem daemon. O guard Docker roda antes da maturidade do perfil e devolve razão de Docker; teste não injeta daemon nessa etapa. Corrigir ordenação e fixture; provar ausência/parada/disponibilidade simulada sem alcançar daemon real. Resultado não autoriza concluir que CI remota falhou: não houve run desta branch.
