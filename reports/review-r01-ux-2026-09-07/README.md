# Avaliação do retorno R01 e oportunidades UX/UI

Base: `ba6adaa`, quatro commits após `a82e2cc`. Revisão documental em worktree própria, sem alteração de produto.

## Parecer sobre retorno do agente

**Aceite local das correções específicas; produto ainda sem aceite integral.** Suíte Homelab passou com daemon externo sombreado (exit127), incluindo parada falha via cmd_down real, rollback por posições, SQLite vivo, reason e layout TSDB. Pytest Player44 + agent/web38: **82 passaram**. Não reexecutei variante contra daemon real; nenhum serviço/VM foi usado.

| Achado anterior | Avaliação |
|---|---|
| R01-001 | Propagação de down corrigida; teste usa helper real e falha do CLI Docker. P0 específico validado em fixture, não certificação geral de dados/produção. |
| R01-002 | Alias capturado no callback; troca de host descarta retorno tardio no cenário testado. |
| R01-003 | Mitigação de comunicação, não instalação por perfil. Aceitável manter REV-007 in_progress; orçamento não equivale a solução entregue. |
| R01-004/005 | Reason retorna no registro; detector reconhece layout com wal/chunks_head/blocos no teste. Snapshot de serviço e consistência banco-anexos permanecem fora do aceite. |
| Evidência | Tiers planned e separação implementação/validação física melhoraram. Sem CI/PR/release nesta revisão. |

## Duas falhas funcionais de UX

**UX-001:** etapa Revisão não tem controle conectado a onboard_confirm_review. Método só é chamado por testes. Clique em Avançar permanece em review. Antes de discutir estética, conectar confirmação no fluxo público e testar por cliques.

**UX-002 (regressão do novo budget):** comparação usa JSON inteiro como hash. Uma variação de memória disponível de16000 para15999MiB já impede aplicar, mesmo com mesmos apps e ambos verdict pass. É possível repetir indefinidamente “Plano mudou” num host com carga variável. Intenção revisada precisa ficar separada de telemetria.

[Provas](probes.json) e [harness reproduzível](check.py). Asserts dos probes registram defeitos, não aceites pós-correção.

## Oportunidades priorizadas

### UX-001 — P1 — Confirmar revisão pelo fluxo visível

Fonte: `linux/ui_native/pages/homelab.py:326`.

onboard_confirm_review só é chamado por testes; nenhum controle de produção conecta a confirmação. Em review, Avançar retorna enquanto confirmed=false. Clique reproduzido permanece preso.

Proposta: Revisão com resumo e botão explícito Confirmar e instalar, conectado à máquina de estados.

Aceite: E2E Qt somente por cliques/teclado chega ao apply; proibido setar flags privadas ou chamar confirmação diretamente no teste.

### UX-002 — P1 — Plano estável apesar de telemetria variável

Fonte: `linux/ui_native/pages/homelab.py:466`.

Hash serializa payload inteiro; budget novo inclui availableMB e diskAvailableMB. Planos reais com 16000→15999 MiB, mesmos apps e verdict pass, impedem execução e exigem revisar de novo.

Proposta: Separar intenção estável e observação; hash de host/apps/config/versão/política; revalidar recursos na execução e pedir nova revisão só por mudança material.

Aceite: Variação inofensiva de RAM/disco não invalida aceite; cruzar limite bloqueia; mudança de apps/host/permissão exige nova confirmação.

### UX-003 — P1 — Homelab com controles inteiros

Fonte: `linux/ui_native/pages/homelab.py:111`.

Capturas 1280x800 e 800x600 mostram grupos comprimidos, botões parcialmente invisíveis e etapas sem espaço.

Proposta: Scroll vertical global, altura mínima de conteúdo, cards adaptativos; remover tabela técnica do modo simples.

Aceite: Todas ações visíveis/alcançáveis por rolagem vertical; testar geometria dos filhos, e não apenas tamanho da janela.

### UX-004 — P1 — Windows VM adapta colunas e ações

Fonte: `linux/ui_native/pages/windows_vm.py:185`.

800x600 mantém duas colunas e linha larga de ações; Iniciar fica cortado e aparece scroll horizontal.

Proposta: Uma coluna em janela estreita, ações refluem; botão principal preservado.

Aceite: 800x600 e 1280x800, escala150/200%, foco/teclado/touch: nenhum CTA cortado e nenhum scroll horizontal necessário.

### UX-005 — P1 — Instalação distinta de simulação de orçamento

Fonte: `linux/ui_native/pages/homelab.py:488`.

Aviso ORÇAMENTO melhora honestidade, mas permanece texto em log+JSON numa etapa que fala aplicar perfil. Usuário não recebe appliance correspondente à escolha.

Proposta: No simples escolher apps instaláveis; perfis sem receita só na área Simular recursos avançada; quadro claro do que será instalado.

Aceite: Escolha de assistente indisponível não instala outros apps com aparência de atender objetivo; aviso legível fora dos logs.

### UX-006 — P2 — Início organizado por objetivo real

Fonte: `linux/ui_native/pages/dashboard.py:32`.

Cinco objetivos coexistem com tutorial IA universal, ações rápidas e ferramentas. Card remoto lista JSON e card Jogos/Android/VM dispara perfil gaming.

Proposta: Objetivos abrem jornada/destino apropriados; primeiro uso específico; retomar tarefa recente; evitar ações genéricas com rótulo de produto completo.

Aceite: Usuário escolhe Windows e chega à instalação Windows; escolhe servidor remoto e chega ao pareamento; IA não exigida para outros objetivos.

### UX-007 — P1 — Modo simples com linguagem e estados de produto

Fonte: `linux/ui_native/pages/homelab.py:297`.

argv, bind, mDNS, dry-run, Nunca --yes e Player PySide6 aparecem para leigo. run_cmd mostra stdout bruto; término vira Concluído/Falhou veja saída.

Proposta: Texto orientado à tarefa, progresso por etapa, motivo e ação de recuperação; JSON/log/portas/provedor em detalhes avançados.

Aceite: Falha de download, autenticação, daemon e espaço explicam causa e oferecem retomar/reparar sem interpretar log.

### UX-008 — P1 — Primeiro acesso remoto dentro da jornada

Fonte: `linux/server/homelab-hosts.sh:526`.

R2 permanece pendente: primeiro SSH exige terminal externo.

Proposta: Pareamento guiado com confiança no host, credencial protegida, timeout/cancel, porta customizada; tecnologia PTY é escolha de implementação, não produto.

Aceite: Máquina sem chave + host novo: completar sem terminal externo, sem senha em argv/log, rejeição/troca de identidade tratadas.

### UX-009 — P1 — Concluir instalação abrindo solução pronta

Fonte: `linux/ui_native/pages/homelab.py:691`.

Card contém Prévia/Ligar/Atualizar, não jornada completa de primeira conta/TLS/Abrir. Running não prova autenticação/configuração de uso.

Proposta: Estados não instalado→preparando→configurar acesso→pronto→abrir; apresentar maturidade e host; readiness funcional compartilhada.

Aceite: Vaultwarden primeira conta/TLS e acesso a partir do admin; Paperless PDF pesquisável; não mostrar pronto por processo rodando.

### UX-010 — P1 — Windows explica capacidade gráfica sem prometer 3D

Fonte: `linux/ui_native/pages/windows_vm.py:198`.

R3 ainda pendente; rótulo Aceleração de vídeo depende de perfil/QEMU, não prova de driver/API no guest.

Proposta: Simples: display recomendado e motivo. Avançado: experimental opt-in, backend e diagnóstico. Monitor/fullscreen separados de aceleração.

Aceite: Guest sem 3D não aparece acelerado; flags sessão/launcher coerentes; teste físico LCD/dock separado.

### UX-011 — P2 — Gate de acessibilidade e usabilidade

Fonte: `tests/test_homelab_player.py:1`.

Testes de handlers não garantem caminho acessível; novos bloqueios passaram com82 testes verdes. Escalas/leitor de tela/usuários reais ainda sem prova nesta revisão.

Proposta: Smoke de jornada por input público; nomes acessíveis/foco/contraste; sessão com leigos e métricas de conclusão/ajuda/retomada.

Aceite: Completar local/remoto/VM com teclado e touch; escalas150/200%; registrar erros, assistência e retomada sem perda de estado.

## Experiência-alvo

No modo simples, mostrar: **objetivo → computador de destino → recursos necessários → resumo da instalação → progresso → configurar acesso → abrir solução**. Em falha: explicar motivo e oferecer uma ação concreta para retomar.

Modo avançado permanece opt-in persistente: manifestos, logs, rede, política, simulação de orçamento, argumentos e gráficos experimentais. Consentimento para uma operação continua separado de ativar modo avançado.

Prioridade sugerida: UX-001/002 → UX-003/004 → UX-005/007/009 → UX-008 → UX-006/010; UX-011 acompanha todas entregas. Evitar ampliar catálogo antes de cada jornada funcionar integralmente.

## Evidência visual

Capturas Qt offscreen com probes/status interceptados: demonstram layout, não saúde real.

- [Homelab1280](Homelab-1280.png), [Homelab800](Homelab-800.png): controles comprimidos/cortados.
- [Windows1280](Windows-VM-1280.png), [Windows800](Windows-VM-800.png): responsividade insuficiente em800.
- [Início1280](Início-1280.png), [Início800](Início-800.png): tutorial genérico precede objetivos.

Somente1280×800 e800×600 foram renderizados;150/200% e acessibilidade assistiva são gates propostos, não validados.

## Handoff

```text
Objetivo: conferir retorno R01 e revisar UX/UI.
IDs: R01 anteriores; novos UX-001..011.
Branch/worktree: codex/review-r01-ux; /mnt/sdcard/Projects/pz-review-r01-ux.
HEAD inicial: ba6adaa; final: commit documental via git log.
Arquivos: reports/review-r01-ux-2026-09-07; Estado vivo/Ledger Homelab e nota no roadmap REV.
Testes: 82 pytest e Homelab shell exit0; 2 probes de falha UX; 6 capturas.
CI/PR: nenhum; nada publicado/instalado.
Host antes/depois: sem workloads/serviços/VM/GRUB alterados; fixtures isoladas.
Segredos: ambiente allowlist, valores sintéticos, diff revisado; gitleaks não executado.
Limites: apenas aceite local; sem teste físico/clean-host/usabilidade com participantes.
Próximo passo: UX-001 ligar confirmação a controle; UX-002 separar intenção e telemetria; validar por input público, depois reflow.
```
