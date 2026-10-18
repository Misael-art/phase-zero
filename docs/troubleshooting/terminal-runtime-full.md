# Terminal não abre: unidade transitória não encontrada

No host misael-jupiter (BigLinux/Manjaro, KDE Wayland), erro observado:
`Unit app-org.communitybig.ashyterm@….service not found`.

## Diagnóstico comprovado em 2026-10-18

- `/run/user/1000` tmpfs 1.554.046.976 bytes, livre 0; gravação pequena falhou
  com errno 28 (`ENOSPC`). Inodes não estavam esgotados.
- `codex-desktop/tmp` ocupava ~1,5 GB, principalmente `pytest-of-misael`
  (~1,42 GB). Artefatos retidos incluíam cópias de DLL/EXE de testes.
- Launcher local `/opt/codex-desktop/start.sh::configure_runtime_tmpdir` define
  TMPDIR em `$XDG_RUNTIME_DIR/codex-desktop/tmp` quando variável não está definida.
  Isso é comportamento observado da distribuição local, não afirmação sobre
  todos os clientes oficiais OpenAI.
- `systemd-run --user --wait --collect --unit=phasezero-terminal-probe-20261018-before /usr/bin/true`
  reproduziu "Unit … not found" enquanto runtime estava cheio.
- Após arquivamento seguro de quatro fixtures inativas, livre 46.239.744 bytes;
  mesmo teste com unidade `phasezero-terminal-probe-20261018-after` passou exit 0.
- Ashy real via unidade `phasezero-ashy-smoke-20261018` abriu janela nova,
  executou somente `/usr/bin/touch` de recibo e fechou. Recibo confirmado,
  ExecMainStatus=0. Nenhuma inferência ou sessão de usuário encerrada.

Unidades transitórias coletadas após término também podem aparecer como
`not-found`; isso isoladamente não prova falha. Aqui falha de criação antes e
sucesso após recuperar espaço comprovam relação com runtime cheio.

[systemd documenta unidades transitórias em XDG_RUNTIME_DIR](https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html).
[pytest documenta temporários e retenção](https://docs.pytest.org/en/stable/how-to/tmp_path.html).

## Reparo sob demanda

`pz repair run terminal --confirm` (próximo pacote contendo este código), ou
`~/.local/bin/reparo-terminal.sh` na instalação imediata por usuário.
Atalhos: **Reparar terminal e sessão**, desktop e menu.

Fluxo pede confirmação. Arquiva cópias verificadas de fixtures com idade mínima
1 hora, sem referências de processos, preservando pytest-current, locks vivos e
locks inválidos. Arquivo original só é removido após comparação e backup em
`~/.local/state/phasezero/terminal-repair/<operação>/`. Symlinks são copiados
como symlinks, sem seguir destinos. Sem sockets especiais, arquivos de outro
usuário, limpeza global do runtime, reset-failed ou restart de systemd/KDE.
Se processos protegidos impedirem leitura de referências, bridge phasezero-admin
pode pedir autorização administrativa apenas para sondagem de `/proc`.

Configura TMPDIR e PYTEST_DEBUG_TEMPROOT em
`~/.cache/phasezero/agent-tmp` e subdiretório `pytest`, fora do runtime. Aplica
ambiente a novos processos systemd do usuário, perfis Bash/Zsh existentes e
`~/.config/environment.d/70-phasezero-agent-tmp.conf`, com backup. Nenhum processo
ativo recebe alteração retroativa de seu ambiente; próximos comandos de agentes
já abertos devem usar esses caminhos explicitamente se não iniciarem novo shell.

Após reparo real: ~44 MB livres, runtime ainda ~98% ocupado. Fixtures atuais e
uma fixture com lock inválido (~730 MB) foram preservadas; não se promete limpeza
total. Se outros produtores continuarem gravando no tmpfs, espaço pode voltar a
acabar. Diagnóstico reporta espaço; confira origem antes de qualquer intervenção.

## Instalação atual e reversão

`python3 linux/repairs/terminal.py install` instala somente helper do usuário,
wrapper e atalho deste reparo; não executa reparo. Código canônico e manager
compartilhado entram no próximo pacote. Pacote instalado permanece 1.22.6-1;
nenhum runtime privilegiado foi copiado manualmente.

Operação real: `20261018-055318-2161652`. Backup de perfis e fixtures em
`~/.local/state/phasezero/terminal-repair/20261018-055318-2161652`.
Para desfazer ambiente, restaurar perfis do backup e arquivo environment.d anterior
(se ausente antes, remover apenas arquivo gerenciado); usar `systemctl --user
unset-environment TMPDIR PYTEST_DEBUG_TEMPROOT` ou restaurar valores anteriores.
Fixtures arquivadas permanecem disponíveis no backup. Não repor no runtime cheio;
se necessário copiar de volta somente com pytest parado e espaço suficiente.

## Handoff

Objetivo: reparar falha recorrente do terminal sem reiniciar desktop/agentes.
Base: 241f84b; branch codex/ashyterm-repair, worktree dedicado pz-ashyterm-repair.
Alterações: helper terminal, manager dos reparos, wrapper, testes, regra local de
temporários e este relatório. Testes direcionados de proteção/arquivamento e
confirmação; comportamento real antes/depois descrito acima. Sem alteração de
worktrees paralelos. CPU/RAM e disco principal também observados, mas não foram
causa comprovada desta falha: havia ~5 GB RAM disponível e ~56 GB livres em disco.
Memória MCP retornou escopo inconsistente ao ler página; relatório local mantém
continuidade, sem alegar gravação durável em escopo não confirmado.
