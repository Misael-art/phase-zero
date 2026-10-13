# Instalação e teste em host real — v1.20.0

Data: 2026-09-09. Host: BigLinux (base Manjaro), AMD, KDE/Wayland.
Escopo autorizado: instalação nativa + diagnóstico somente leitura. Sem subir
serviço, sem instalar app, sem ligar VM, sem aplicar tuning, sem reiniciar.

## Instalação

| Item | Resultado |
|---|---|
| Origem | `phasezero-control-center-1.20.0-1-any.pkg.tar.zst` do release v1.20.0 |
| Integridade | sha256 conferido contra `SHA256SUMS-1.20.0`: **SUCESSO** |
| Método | `pacman -U` pela ponte `phasezero-admin` (uma aprovação gráfica) |
| Antes → depois | `phasezero-control-center 1.19.0-1` → **1.20.0-1** |
| `pz` no PATH | **ausente antes, presente depois** (`/usr/sbin/pz`, `PhaseZero Linux v1.20.0 (stable)`) |

O `pz` no PATH é a correção de empacotamento desta release chegando ao host: na
1.19.0 o binário não era instalado, e a 1.20.0 só empacotou depois que o
`%files` do RPM foi corrigido. Aqui é o pacote Arch, mas a mesma linha de
instalação vale para os dois formatos.

### Correção de uma afirmação minha anterior

Antes de instalar, eu disse que este host tinha **conflito de canais** (nativo +
usuário). Estava errado. O que existe é um symlink pendurado
`~/.local/share/phasezero/current -> releases/1.10.0`, e esse diretório não
existe mais. O produto reporta corretamente:

```
status: ok        activeChannels: ['native']
user:   {"installed": false, "version": "", "root": ""}
conflicts: (nenhum)
```

Ou seja: a checagem de canal se comporta como deveria diante de um resto de
instalação antiga — não conta symlink quebrado como canal ativo.

## Testes executados (somente leitura)

| Comando | rc | tempo | Resultado |
|---|---|---|---|
| `pz installation status` | 0 | — | canal único, sem conflito |
| `pz server homelab status --json` | 0 | 3,0 s | `stopped`, "no homelab containers running", próximo passo declarado |
| `pz server homelab apps list --json` | 0 | 9,6 s | 10 apps user-facing, **cópia pt-BR presente** |
| `pz server homelab prepare --dry-run --profile edge` | 0 | 2,3 s | perfil orçamento declarado, 4 apps padrão, `budget: pass` |
| `pz windows-vm graphics status --json` | 0 | 0,6 s | recomenda `compat`; `virtio-gl` = experimental |
| `pz emulation dualscreen detect` | 0 | **0,4 s** | DP-1 2560x1080 + eDP-1; índices KWin `unknown` |
| GUI (offscreen, código instalado) | 0 | 0,8 s | Início, Homelab e Windows VM constroem |
| `pz doctor` | **141** | 3,0 s | **trunca — ver defeito abaixo** |

### O que as rodadas UX entregaram, verificado no host instalado

- **UX-009**: `apps list --json` devolve `firstUse.stepsPtBr`. Vaultwarden:
  *"Abra e crie a PRIMEIRA conta — o cadastro fecha depois dela."*, com
  `openUrl` `http://127.0.0.1:8222/`.
- **UX-005**: `prepare --dry-run --profile edge` declara `profileInstallable:
  false` e `profileServices: [zeroclaw, 9router]` — a verdade que a interface
  usa para exigir decisão explícita.
- **UX-010**: este host **tem** render node e QEMU com `virtio-vga-gl` e venus,
  e `virtio-gl` está elegível sem bloqueios. Ainda assim o backend o classifica
  como experimental, e por isso o diálogo simples oferece **só** `compat`, com o
  motivo à vista: *"Recomendado para esta máquina: compat. … VirtIO GL valida
  caminho host, sem garantir 3D no Windows"*. É exatamente o aceite: máquina
  capaz não vira promessa de 3D.
- **UX-011**: contraste sem falhas nos dois temas, medido contra os tokens
  instalados.
- **dualscreen**: `detect` responde em 0,4 s. Antes da correção desta release,
  `kscreen-doctor` pendurava a chamada indefinidamente.

## Defeitos encontrados no host

### 1. `pz doctor` morre no meio e não completa o diagnóstico

`pz doctor` sai com **141 (SIGPIPE)** e o relatório para em `WINVM10`, na linha
74. Tudo que vem depois — `WINVM11` (integração gráfica), TPM, swtpm e o restante
— **nunca é avaliado**. O usuário vê um relatório que parece ter terminado.

Causa, em `linux/audit/doctor.sh:380`:

```bash
last_op_dir="$(ls -t "$winvm_ops_dir" 2>/dev/null | head -1)"
```

Sob `set -euo pipefail`, `head -1` fecha o pipe, `ls` recebe SIGPIPE, o pipeline
retorna 141 e o `set -e` encerra o script. Reproduzido isolado:

```
$ ls ~/.local/state/phasezero/operations | wc -l
5118
$ bash -c 'set -euo pipefail; x="$(ls -t "$d" | head -1)"'
rc=141
```

Só dispara quando o diretório tem entradas suficientes para `ls` ainda estar
escrevendo quando `head` sai — por isso não aparece em CI, onde o diretório não
existe. É a mesma classe que o próprio CI sinaliza como aviso não bloqueante
("pipefail + grep -q"). Vale para o `pz` instalado e para o código do
repositório: mesma versão, mesmo comportamento.

### 2. `pz doctor --json` ignora a flag

`pz doctor --json` imprime o relatório humano, não JSON. Um comando que promete
saída de máquina e devolve texto quebra qualquer consumidor — e é o mesmo tipo de
contrato que a suíte `test_status_contract.py` protege para os outros comandos.

### 3. 5118 diretórios de operação acumulados

`~/.local/state/phasezero/operations` tem 5118 entradas. Além de ser o gatilho do
defeito 1, é higiene: não há poda. Cada operação de provisionamento deixa um
diretório para trás.

### 4. Runtime de boot do Windows VM desatualizado (esperado, não corrigido)

O pós-install avisa e o doctor confirma: `[FAIL] WINVM16`. O
`/usr/local/lib/phasezero/windows-vm-runtime` ainda tem o código anterior, então
a entrada GRUB "PhaseZero Windows VM" rodaria a versão velha. A correção é
`phasezero-admin pz windows-vm boot install` — **não executei**: mexe em boot, e
o combinado desta sessão era não tocar em boot nem reiniciar.

## Correções aplicadas (738ec28)

| Defeito | Correção | Prova |
|---|---|---|
| doctor morria com SIGPIPE | ordenação sem pipe, e o glob visita só diretórios `op-*` | **44 → 136 checks** neste host; teste dirige o `pz doctor` real contra um diretório montado para disparar o crash antigo |
| `--json` ignorado | envelope objeto (`schemaVersion`, `summary`, `ok`, `checks[]`), saída 0 como comando de status, e flag desconhecida agora é recusada | primeira linha é `{`, relatório humano não vaza, `--nao-existe` falha |
| estado sem poda | check `STATE01` conta e aponta `pz installation prune` | `WARN … 5126 registros … poda: pz installation prune` |

Sem as correções, a suíte morre com 141 — verifiquei revertendo só os arquivos
de produto e mantendo os testes.

## Achado adicional: suíte órfã — corrigido

`tests/audit-doctor.sh` falhava neste host e **nunca rodava no CI**: o
`tests/runner.sh` varre `tests/linux-*.sh` e `tests/test_*.sh`, e o nome não
casava com nenhum dos dois padrões.

O caso `default_conservative` guardava uma regra que o produto abandonou de
propósito. O commit `82460f7` (CCS-016) inverteu a política — *"ausência de conf
= nunca optou; host fresco não pode virar parede de WARN por subsistema que o
usuário nunca pediu"* — e o doctor passou a responder `INFO: not opted in`. O
teste continuou exigindo `WARN`, e ninguém viu, porque ninguém o executava.

Correção: o caso passa a afirmar a regra atual (INFO, e **nenhum** WARN para
subsistema não solicitado), e o arquivo virou `tests/linux-audit-doctor.sh`,
que o runner enxerga. 9 casos, todos verdes.

## Limites desta verificação

- Nada foi exercido de ponta: nenhum app instalado, nenhuma primeira conta
  criada, nenhum pareamento contra sshd real, nenhuma VM iniciada. O aceite aqui
  é de instalação e diagnóstico, não de jornada completa.
- A GUI foi validada offscreen (constrói e navega). Não houve interação humana
  com a janela real nem sessão com participante.
- Depois da correção o `pz doctor` completa e avalia 136 checks neste host,
  mas o binário instalado em `/usr/lib/phasezero` **continua com o defeito**:
  a correção está no repositório e só chega ao host numa próxima release.
- `tests/audit-doctor.sh` segue vermelho e fora do runner.
