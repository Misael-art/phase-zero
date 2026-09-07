# Revisão de conclusão — Windows VM, Homelab, IA e UI

**Conclusão: não aceitar como pronto para lançamento geral.** Correções úteis existem; persistem falha P0 de restore, bugs de onboarding, contrato gráfico incompatível e provas incompletas. Revisão do código em `9d6be9d`, ponta local `codex/aud-fase5`, com fases anteriores incluídas. `origin/main` continua `2180c94`. Nenhuma PR/run da fase 5 encontrada na consulta GitHub de 07/09/2026.

## Entregas

- [18 achados com causa, fonte e aceite](ACHADOS.md).
- [Backlog para agente](backlog.json), todos pendentes, prioridade e relação com auditoria/WBR.
- [Reconciliação individual dos 31 itens marcados como concluídos](RECONCILIACAO.md).
- [Plano de conclusão e certificação](PLANO.md).
- [Cinco reproduções de defeitos](reproductions.json), usando [funções reais e fixtures](reproduce.py).
- Capturas Qt: [Início](home.png), [Windows VM](windows.png), [Homelab](homelab.png). Status/probes foram interceptados; capturas demonstram layout e navegação, não saúde real dos serviços.

## Resultado Windows VM

| Requisito | Parecer |
|---|---|
| Instalação/provisionamento/integrações | Estrutura substancial existente: provisioner, QGA, arquivos, USB, RDP, controles e runtime de sessão. E2E completo não executado nesta revisão. |
| Iniciar desde boot em fullscreen | Fluxo existe. Runtime real segue 1.16.6, pacote 1.19.0 e marker pendente; não certificável ainda. |
| Monitor externo / resolução | Resolver distingue painel e dock. Flags não provam modo efetivo no Windows. Exigir LCD, monitor externo, DPI, refresh, troca e ausência de monitor com evidência no guest. |
| Decidir aceleração | Não coeso: auto da sessão gera flags recusadas pelo launcher. Perfis e UI também divergem sobre stable/experimental e 3D. |
| Robustez | Sessão graciosa e retries têm testes; fallback pós-crash, reparo escalado e incidente histórico de armazenamento precisam conclusão. Nenhum erro de armazenamento atual foi inferido dos registros antigos. |
| Desenvolvimento nativo | Candidato para editor, Git, compilação e depuração, condicionado a disco/recursos e estabilidade. Não foi testada uma compilação dentro desta VM. |
| WSL2 / Docker dentro da VM | Condicional à virtualização aninhada no guest, recursos Windows, reboot e engine. Parâmetro nested=1 no host não certifica o convidado. |
| Desenvolvimento 3D / jogos / CUDA | Não anunciar suporte por `virtio-gl`/QEMU presente. Requer driver/API/carga real no guest; VFIO/Venus permanecem planos/experimentais conforme código. |

QEMU distingue backend 2D e backends acelerados; isso não substitui validação do driver convidado ([documentação QEMU](https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html)). Microsoft exige virtualização aninhada para WSL2 em VM ([FAQ WSL](https://learn.microsoft.com/en-us/windows/wsl/faq#can-i-run-wsl-2-in-a-virtual-machine)). Para este projeto, a ausência das provas acima é conclusão da inspeção local, não declaração de impossibilidade técnica.

## Resultado UX

Modo avançado persistente existe e começa desligado. Windows VM ganhou organização visual útil, ações primárias e manutenção. Porém toggle “Aceleração de vídeo” não representa capacidade comprovada. Homelab comprime controles até cortá-los em 1280×800. Início mantém primeiros passos voltados a IA independentemente do objetivo e soma cinco cards a taxonomia com 20 categorias. “Cuidar de outro computador” ainda executa listagem JSON, não assistente completo.

Meta: modo simples apresenta objetivo, destino, prontidão, uma ação principal e recuperação. Modo avançado opt-in contém política, logs, argumentos, perfis experimentais e ajustes. Mesma semântica de estado nas superfícies; leigo não precisa interpretar argv, bind, mDNS, dry-run ou GRUB para concluir jornada.

## Validação executada

| Verificação | Resultado | Limite |
|---|---|---|
| Pytest direcionado | **135 passed**; [saída](pytest.txt) | Qt, dependências, perfis, contratos agente/web; não pytest completo |
| Sessão Windows | Passou; [saída](test_windows_vm_session.txt) | Launcher fake; não boot físico |
| Gráficos Windows | Passou; [saída](linux-windows-vm-graphics.txt) | Probes/QEMU/virsh simulados e dry-run |
| Proxies IA | Passou; [saída](linux-ai-proxies.txt) | Sem login/inferência reais |
| Homelab shell | **Falhou** em `FAIL: refusal hides maturity`; [saída](linux-homelab.txt) | Daemon indisponível por design no sandbox; resto da suíte após esse ponto não executado |
| Reprodução independente | Cinco defeitos confirmados | Multiline, pair=false, confirmação entre hosts, flags GL, perda parcial restore |
| Host read-only | [metadados](host-readonly.json) | Sem boot/sync/serviço alterado; sem inspeção de credenciais |
| GitHub | main não contém fases; sem PR/run fase5 | Definição de job não é execução |

`reproduce.py` contém assertions do comportamento defeituoso. Após corrigir, deve falhar nesses asserts; aceite futuro precisa testes que exijam comportamento correto. Executar `python reports/review-remediation-winvm-ux-2026-09-07/run-reproductions.py` na worktree: wrapper cria HOME/XDG descartáveis, ambiente por allowlist e ferramentas bloqueadas. Não executar o reprodutor interno fora dessa contenção. `sandbox.txt` registra o diretório temporário usado; variáveis reais/credenciais não foram persistidas no repositório.

## Handoff obrigatório

```text
Objetivo da sessão: verificar conclusão do agente e auditar Windows VM/UX.
Fase/IDs assumidos: revisão PZ-AUD-001..031; novos REV-001..018, WBR relacionados.
Branch e worktree: codex/review-remediation-winvm-ux; /mnt/sdcard/Projects/pz-review-remediation-winvm-ux.
HEAD inicial: 9d6be9d (ponta da entrega examinada, derivada de main).
HEAD final: commit documental desta revisão; consultar git log.
Arquivos alterados: somente reports/review-remediation-winvm-ux-2026-09-07 e Estado vivo/Ledger dos roadmaps aplicáveis.
Commits criados: documentação/evidências, nenhum runtime corrigido.
Testes executados e resultados: tabela acima; Homelab não está verde.
CI/PR: nenhuma PR/publicação criada; fases locais não integradas ao main consultado.
Estado do host antes/depois: pacote/VM/GRUB/serviços/workloads inalterados; fixtures e render offscreen apenas.
Segredos verificados como ausentes: resultados de fixtures/metadados; inspeção de conteúdo do diff; sem ler env real; gitleaks local não executado.
Limitações e riscos restantes: P0 restore; armazenamento histórico sem fechamento; nenhum clean Windows/Arch E2E, login real ou boot físico nesta revisão.
Bloqueios reais: lançamento integral carece correções/provas; auditoria documental concluída.
Próximo passo exato: REV-001 com ENOSPC/cp parcial reproduzido; em seguida REV-002/003 e testes isolados REV-018; depois onboarding e contrato WBR antes de certificação física.
```
