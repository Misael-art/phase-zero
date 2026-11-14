# Investigação de travamentos e captura limitada

O fluxo `pz repair stability` reúne o diagnóstico de captura do host e duas
correções reversíveis: excluir o greeter SDDM do autoaplicador ICC do BigLinux
e configurar um journal persistente de até 150 MiB, sincronizado a cada 60 s.
Isso não identifica a causa de um reset nem comprova estabilidade do host.

No checkout, use `linux/pz` para executar a revisão atual; um `pz` instalado
em outro release pode ainda não conhecer este comando.

```bash
linux/pz repair stability status
linux/pz repair stability plan
linux/pz repair stability apply --yes
linux/pz repair stability rollback --yes
```

`status`, `plan` e ajuda são somente leitura e nunca abrem autenticação.
Aplicação e reversão exigem confirmação explícita `--yes` e usam o bridge
administrativo existente: `phasezero-admin`, ou Bigsudo quando disponível.
O JSON mantém dados ilegíveis ou ausentes como desconhecidos. A aplicação
recusa reduzir uma retenção já maior, tornar a sincronização já configurada
menos frequente, ou prosseguir quando esses valores não estão comprovados.

## Efeitos e propriedade

O reparo cria somente:

- `/etc/systemd/user/plasma-big-apply-icc.service.d/60-phasezero-no-greeter.conf`
  com `ConditionUser=!sddm`. A unit original do pacote e a condição `!root`
  permanecem. A configuração passa a ser lida na próxima entrada natural
  do greeter; o reparo não reinicia o desktop, SDDM ou o perfil de cor atual.
- `/etc/systemd/journald.conf.d/60-phasezero-stability.conf` com
  `Storage=persistent`, `SystemMaxUse=150M` e `SyncIntervalSec=60s`.
  A ativação usa uma operação `systemctl restart systemd-journald.service`.
  O [systemd documenta que os streams sobrevivem a esse restart](https://www.freedesktop.org/software/systemd/man/latest/systemd-journald.service.html).
  Não usar um par separado de stop/start.

Arquivos de mesmo nome preexistentes sem recibo, links simbólicos, diretórios
inseguros e configurações alteradas são preservados. O recibo privado fica em
`/var/lib/phasezero/repairs/stability/state.json`; registra intenção antes do
efeito, hashes, identidade da operação e fase. Não sobrescrevemos os arquivos
originais, portanto a reversão consiste em remover somente os dois arquivos
criados e ainda idênticos ao recibo, depois reativar o journal original.
O limite de espaço é de retenção, não uma garantia do número de boots; outras
restrições do journald e a quantidade de mensagens também influem.

Aplicação idempotente não reinicia o logger novamente. Falha ou timeout de
ativação deixa resultado desconhecido registrado; uma nova aplicação é
bloqueada até verificar o estado ou executar reversão explícita. Uma falha
parcial de escrita também mantém recibo para revisão/reversão. Nenhum arquivo
de logs é apagado pelo reparo.

## Aceite e limites de captura

Após aplicar, conferir configuração efetiva e serviço do journal. Na próxima
entrada natural no greeter, verificar que o autoaplicador ICC não executa sob
`sddm`; no login do usuário, verificar seu perfil de cor. Teste sintático ou
condição avaliada sob outro UID não substituem essa observação física.

O diagnóstico mostra backend pstore, estado da EFI, disponibilidade reportada
das variáveis EFI, configuração do frontend de console, flags de diagnóstico
e watchdogs. Capacidade das variáveis EFI é diferente do espaço na partição
de boot. Não habilita pstore, reserva RAM para ramoops, muda flags de boot,
atualiza firmware nem habilita panic ou reboot automático.

Quando esses mecanismos estão desativados, ausência de registro de falha não
prova saúde. Um backend pstore pode capturar panic/oops, mas não garante um
dump durante todo hardlock nem quando a energia desaparece antes da escrita.
Qualquer mudança posterior de boot exige backend compatível, janela e caminho
de recuperação validados; não provocar panic, calor ou esgotamento de RAM/I/O.

Fôlego continua owner das amostras passivas de recursos/energia; SteamZero,
das transições e saída de Gamescope. Este reparo não cria outro daemon nem
substitui esses históricos.
