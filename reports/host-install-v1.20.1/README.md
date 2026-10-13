# Instalação e teste em host real — v1.20.1

Data: 2026-09-09. Host: BigLinux (base Manjaro), AMD, KDE/Wayland — o mesmo da
verificação da 1.20.0, o que torna a comparação direta.
Escopo: instalação nativa + diagnóstico somente leitura. Sem subir serviço, sem
ligar VM, sem tocar em boot, sem reiniciar.

## A pergunta desta rodada

A 1.20.1 existe para corrigir três defeitos achados ao instalar a 1.20.0 aqui.
A prova não é "os testes passam" — é o mesmo comando, na mesma máquina, antes e
depois.

| Medida | 1.20.0 instalada | 1.20.1 instalada |
|---|---|---|
| `pz doctor` código de saída | **141 (SIGPIPE)** | 1 (há FAIL nos checks — relatório concluído) |
| Checks avaliados | **48** | **138** |
| Onde parava | `WINVM10`, em silêncio | chega ao Summary |
| `pz doctor --json` | relatório humano | envelope objeto, `rc=0` |
| Flag desconhecida | aceita em silêncio | recusada (`rc=1`) |

O comando levava 3 s porque morria; agora leva 55 s porque termina.

### O que a 1.20.0 nunca chegou a medir neste host

Seis checks vinham depois do ponto de morte e nunca eram avaliados. Agora são —
e não são decorativos:

```
FAIL WINVM16   Windows VM boot runtime matches this install
WARN WINVM11   Windows graphics integration
WARN WINVM12   (integração Windows)
PASS WINVM13   Windows guest concurrency
PASS WINVM14   swtpm daemon running
WARN WINVM15   (integração Windows)
```

`WINVM16` é uma falha real: o caminho GRUB roda runtime antigo. Estava lá o
tempo todo; o diagnóstico é que não chegava até ela.

### Envelope JSON

```json
{"schemaVersion":1,"tool":"doctor","ok":false,
 "summary":{"pass":68,"warn":40,"fail":3,"error":0,"info":26,"total":137}}
```

Sai 0 como comando de status deve sair, com o veredito em `ok`.

### STATE01, o check novo

```
WARN  Local operation records bounded
      5262 registros em ~/.local/state/phasezero/operations; poda: pz installation prune
```

Cresceu de 5126 para 5262 desde a rodada anterior — o acúmulo é contínuo, e
agora o produto avisa em vez de deixar o usuário descobrir quando algo quebra.

## Instalação

| Item | Resultado |
|---|---|
| Origem | `phasezero-control-center-1.20.1-1-any.pkg.tar.zst` do release v1.20.1 |
| Integridade | sha256 conferido contra `SHA256SUMS-1.20.1`: **SUCESSO** |
| Método | `pacman -U` pela ponte `phasezero-admin` |
| Antes → depois | `1.20.0-1` → **1.20.1-1** (`PhaseZero Linux v1.20.1 (stable)`) |

## Resto da bateria (somente leitura)

| Comando | rc | tempo |
|---|---|---|
| `pz installation status` | 0 | 0,4 s |
| `pz server homelab status --json` | 0 | 5,1 s |
| `pz server homelab apps list --json` | 0 | 24,8 s |
| `pz windows-vm graphics status --json` | 0 | 0,8 s |
| `pz emulation dualscreen detect` | 0 | 0,5 s |

Sem regressão no que a 1.20.0 já entregava: cópia pt-BR do primeiro acesso
presente (*"Abra e crie a PRIMEIRA conta — o cadastro fecha depois dela."*) e
`recommended.profile = compat` mesmo com o host tendo render node e QEMU capaz.

## Três FAIL que continuam de pé (não são regressão)

- `DISK__mnt_sdcard: 92% used` — disco do host.
- `CPU01: 90°C` — temperatura, acima do limite de 85 °C.
- `WINVM16` — runtime de boot desatualizado; a correção mexe em boot e ficou
  fora do combinado desta sessão.

## Limites

- Diagnóstico e instalação. Nenhum app instalado num servidor, nenhuma primeira
  conta criada, nenhum pareamento contra sshd real, nenhuma VM iniciada.
- O `pz doctor` demora 55 s neste host; não investiguei o custo por check.
- `WINVM11/12/15` estão em WARN e passaram a ser visíveis agora. Não os
  investiguei — apareceram nesta rodada porque antes ninguém os media.
