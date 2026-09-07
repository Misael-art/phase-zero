# Plano para encerrar lacunas

Não ampliar promessa stable antes de completar provas. Preservar branches do agente; corrigir em frente própria, com teste do defeito antes e depois. Não instalar workloads nem alterar boot do host em uso nesta fase.

## 1. Dados e critérios de conclusão

REV-001 → REV-002/003 → REV-018/017. Primeiro remover perda parcial e falsa recuperação. Acrescentar testes de escrita concorrente e interrupção; somente depois retomar aceite de backup/restore. Estados separados: implementado, regressão local, CI, E2E plataforma, físico, entregue em release. `verified` exige aceite correspondente, não fechamento narrativo.

Gate: nenhum volume alterado fora do conjunto; falha de cópia em qualquer etapa preserva dados originais ou estado recovery-required preciso; bancos reais passam integridade e invariantes após restauração.

## 2. Onboarding funcional

REV-004/005 → REV-006/007 → REV-008. Parser completo compartilhado; pareamento positivo vinculado ao host; seleção efetiva no plano; aceite vinculado a hostId/perfil/apps/revisão; primeiro SSH guiado. Saída amigável e detalhes opcionais.

Gate: admin sem Docker pareia appliance novo, escolhe apps, revisa, instala e abre serviço; erro/rede/host trocado não reaproveita autorização. Teste usa stdout real da CLI, não JSON compacto inventado.

## 3. Windows VM: contrato antes do hardware

REV-009/010 → REV-012 → REV-011 física. Contrato único resolve host/backend/driver/consentimento. Separar resolução, fullscreen e aceleração: monitor presente não é motivo suficiente para ativar perfil experimental. Compat pode ser escolha correta e precisa boa resolução. Plano deve informar motivo e fallback, com resultado observado depois do boot.

Política proposta:

1. Detectar KVM acessível, backend raw/libvirt, saída física, resolução/refresh, driver guest e recursos.
2. Se não houver prova de aceleração convidada, selecionar perfil gráfico comprovado para display; não prometer 3D.
3. Experimental exige opt-in persistente específico; não reutilizar preferência do host anterior.
4. Falha antes de guest iniciado pode ter fallback. Crash após guest iniciar exige confirmação de parada e recuperação; não repetir boot sobre disco possivelmente sujo.
5. Runtime instalado precisa corresponder ao pacote. Upgrade prepara sincronização/reversão; autorização administrativa aparece no momento necessário.

Gate hermético: sessão chama launcher real com QEMU stub, cobrindo cada backend/flag/consentimento e fallback tardio. Gate físico separado: resolver investigação histórica de armazenamento com operador; boot frio LCD 1280×800 e monitor nativo; verificar resolução dentro do Windows, fullscreen, foco, teclado/USB, áudio, QGA shutdown, atualização do Windows e reparo. Testar ausência de monitor e troca de dock. Não inferir sucesso de `--validate`.

## 4. Windows para desenvolvimento

REV-013. Dois níveis: “Desenvolvimento Windows” e “WSL2/containers” opcional. Instalar toolchain por manifesto e validar build/test/debug de projeto público pequeno; retomar após reboot, recursos negados e download interrompido. Workspace compartilhado precisa política explícita, watchers/paths/permissões testados e backup independente do rollback da imagem.

Para WSL2: verificar nested no guest, features Windows, reinício pendente, distro e engine; oferecer execução de containers no host Linux/remoto quando nested não for suportado, somente por escolha informada. Para 3D/IA GPU: API e carga alvo medidas no convidado, sem deduzir desempenho de `gl=on`.

Gate: instalar → clonar → compilar → testar → depurar → reiniciar → continuar → restaurar workspace. Publicar RAM/disco/download medidos, hardware usado e limites; nenhuma alegação de desempenho antes do benchmark.

## 5. UX e IA por maturidade

REV-014/015/016. Corrigir clipping antes de acrescentar cards. Modo simples: cinco objetivos navegáveis, destino explícito, custo real, progresso e próximo passo. Primeiro uso responde ao objetivo; IA não é requisito universal. Modo avançado opt-in mantém capacidades completas sem expor ferramentas experimentais como prontas. Migração de MiMo Windows e autenticação real por provider precedem paridade.

Gate visual: 1280×800, 800×600 e escalas 150/200%; nenhuma ação cortada; teclado/touch; leitura do estado por tecnologia assistiva. Gate de uso: pessoas leigas completam instalação local/remota e Windows sem terminal externo; registrar taxa de conclusão, erros, retorno após interrupção e intervenções necessárias.

## 6. Integração, certificação e publicação

PR a partir da cadeia revisada, CI pelo SHA final e testes descartáveis. Arch: instalar asset em VM oficial mínima como usuário comum; nenhum Docker/Node/helper preexistente; preparar serviço real, abrir, reiniciar e retomar. Windows: máquina limpa, sem winget/WSL prontos em cenário alternativo; dependências e reboots retomáveis. Além de Vaultwarden, cada app stable realiza seu caso de uso (PDF/OCR, sync entre dispositivos, workflow, upload/download, métricas, mídia).

Publicar matriz por solução/hardware/plataforma com links de job e artefatos. Só então release canônica, checksums e upgrade testado. Não tratar container Arch com ferramentas previamente instaladas e dry-run como substituto desses gates.
