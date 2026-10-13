# PhaseZero

Instalador e painel para **depois** de instalar o sistema: Windows, Linux, Steam Deck e um Homelab que você administra de outro computador.

Não é umbrelOS. Não é um “app store” da comunidade. É o mesmo produto em dois papéis: uma máquina **funciona como Homelab**; a outra **administra e consome**.

[![CI](https://github.com/Misael-art/PhaseZero/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Misael-art/PhaseZero/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Misael-art/PhaseZero)](https://github.com/Misael-art/PhaseZero/releases/latest)
[![Plataformas](https://img.shields.io/badge/plataformas-Windows%20%7C%20Linux%20%7C%20Steam%20Deck-6c5ce7)](#o-que-o-projeto-faz)
[![Idioma](https://img.shields.io/badge/interface-portugu%C3%AAs%20do%20Brasil-009c3b)](#)

**[Instalar](#instalar)** · **[Página Linux](#página-linux-apps-serviços-e-otimizações)** · **[Homelab](#homelab-dois-pcs-um-produto)** · **[CLI](#cli-rápido-quando-o-painel-não-chega)** · **[Segurança](#segurança-o-que-o-leigo-precisa-saber)** · **[Changelog](CHANGELOG.md)**

---

## O que o projeto faz

| Superfície | Para quem | O que você sente |
|---|---|---|
| **Windows** | PC limpo / pós-format | Bootstrap seguro (dry-run, perfil pequeno, rollback) |
| **Control Center** | Linux / Steam Deck | App Qt: Homelab, VM Windows, emulação, IA, temas |
| **Homelab** | Um PC servidor + um PC do sofá | Apps um clique, backup verificável, dashboard HTTPS, Tailscale |

Três regras que não mudam:

1. **Dry-run antes de mutar.** Plano visível; apply só com confirmação.
2. **Segredo nunca na tela.** Hash, referência, arquivo `0600` — não cola de API key.
3. **Falha fechada e honesta.** Dado ausente aparece *indisponível*. Sem `latest`. Sem abrir a WAN sozinho.

---

## Homelab: dois PCs, um produto

Este é o modelo que o projeto assume. Co-localizar os dois papéis no mesmo computador é opt-in, não o desenho.

```mermaid
flowchart LR
    C["Celular · TV · notebook<br/>consomem os serviços"]
    A["PC Homelab (appliance)<br/>PhaseZero para FUNCIONAR<br/><br/>compose + backups<br/>Tailscale · agente + mDNS<br/>dashboard web HTTPS"]
    B["PC Admin (Player)<br/>PhaseZero para ADMINISTRAR<br/><br/>painel desktop<br/>seletor de host<br/>pareamento SSH / token"]
    C -->|Jellyfin · Vaultwarden · Nextcloud| A
    B <-->|LAN / Tailscale| A
```

<details>
<summary>Mesma topologia em texto puro</summary>

```text
Celular, TV, notebook da casa
        │  consomem Jellyfin / Vaultwarden / Nextcloud
        ▼
┌───────────────────────────┐     LAN / Tailscale     ┌───────────────────────────┐
│  PC Homelab (appliance)   │◄───────────────────────►│  PC Admin (este, Player)  │
│  PhaseZero para FUNCIONAR │                         │  PhaseZero para ADMINISTRAR│
│                           │                         │  e CONSUMIR                │
│  compose + backups        │                         │  Player desktop            │
│  Tailscale                │                         │  seletor de host           │
│  agente + mDNS            │                         │  pareamento SSH / token    │
│  dashboard web HTTPS      │                         │  Abrir dashboard           │
└───────────────────────────┘                         └───────────────────────────┘
```

</details>

| Papel | Onde instala | O que **não** faz |
|---|---|---|
| **Appliance** | O outro PC, o que fica ligado | Não precisa de teclado o dia todo |
| **Admin / Player** | O PC em que você senta | **Não** sobe Docker da stack Homelab |

Fora de casa o caminho é **Tailscale**. Não há UPnP nem port-forward.

---

## Página Linux: apps, serviços e otimizações

Uma vitrine categorizada com tudo o que o projeto entrega no Linux. Sem caçar comando no
terminal e sem adivinhar o que já está ligado.

![Control Center — página Linux](docs/images/control-center-linux.png)

Cada cartão mostra:

| Elemento | Para que serve |
|---|---|
| **Ícone e nome** | Ícone real do app instalado, lido do `.desktop`. Nada é baixado da internet. |
| **Descrição** | O que aquilo faz, em uma linha. |
| **Interruptor** | Ligado = instalado / aplicado. Desligado = ausente. |
| **Selo de reversão** | Como se desfaz: pacote, Flatpak, arquivo de backup, valor anterior — ou `manual`/`sem reversão`, sem pintar de verde o que ninguém desfaz sozinho. |
| **Selo de modo** | `Recomendado`, `Opcional` ou `Avançado`. |

Três garantias que valem para todo interruptor:

1. **Prévia antes de mutar.** Ligar dispara um plano; nada acontece sem sua confirmação.
2. **Estado nunca otimista.** O interruptor fica em *aplicando…* e só assume o novo valor
   quando o host reconfirma. Prévia recusada devolve o botão ao lugar.
3. **Não sondado ≠ desligado.** Se a leitura falhar, o controle fica inerte e diz o motivo,
   em vez de exibir um "desligado" em que você poderia agir por engano.

O equivalente em linha de comando:

```bash
# Recursos: sondar, planejar, aplicar, remover. Toda saída já é JSON.
linux/pz capabilities status
linux/pz capabilities plan --capability gaming.mangohud
linux/pz capabilities apply --plan-id <id-do-plano> --confirm <token>
linux/pz capabilities remove-plan --capability gaming.mangohud
linux/pz capabilities remove --plan-id <id-do-plano> --confirm <token>

# Otimizações por área (gaming | browser | dev).
linux/pz tune gaming status                  # estado real, com aviso de drift
linux/pz tune gaming apply --dry-run         # plano, sem tocar em nada
linux/pz tune gaming revert                  # volta ao que era seu
```

O `id` e o `token` saem do próprio `plan`/`remove-plan`: aplicar exige o plano que você
acabou de ver, não um comando solto. O painel faz esse encadeamento por você.

`revert` guarda o arquivo original e o valor anterior de cada preferência de ferramenta;
o que era seu volta a ser seu, em vez de simplesmente sumir.

---

## Instalar

Sempre pela [página de Releases](https://github.com/Misael-art/PhaseZero/releases/latest). Cada versão traz **7 artefactos** + `SHA256SUMS-<versão>`.

### 1. Baixar e conferir o checksum

```bash
# exemplo: última estável (substitua a versão pelo nome do ficheiro na Release)
sha256sum -c SHA256SUMS-1.19.0
```

Se a linha do pacote não for `OK`, **pare**. Não instale.

### 2. Pacote da sua distro

| Sistema | Ficheiro | Comando |
|---|---|---|
| Arch / Manjaro / BigLinux | `phasezero-control-center-*-any.pkg.tar.zst` | `sudo pacman -U ./ficheiro.pkg.tar.zst` |
| Debian / Ubuntu | `phasezero-control-center_*_all.deb` | `sudo apt install ./ficheiro.deb` |
| Fedora / openSUSE | `phasezero-control-center-*.noarch.rpm` | `sudo dnf install ./ficheiro.rpm` |
| Qualquer Linux (sem root) | `PhaseZero-*-x86_64.AppImage` | `chmod +x PhaseZero-*.AppImage && ./PhaseZero-*.AppImage` |
| Flatpak | `PhaseZero-*.flatpak` | `flatpak install --user PhaseZero-*.flatpak` |

A instalação acima usa o `sudo`/`pkexec` do sistema uma única vez — a bridge
`phasezero-admin` ainda não existe num host limpo. Em seguida, prepare a
bridge (sem root, uma vez por usuário) e confirme o CLI no PATH:

```bash
pz --version                    # /usr/bin/pz vem no pacote; sem checkout
pz ai setup admin               # cria ~/.local/bin/phasezero-admin
pz ai admin status              # ready=true antes de qualquer mutação
```

A partir daqui prefira `phasezero-admin` (ou `bigsudo`) em vez de `sudo` sem contexto. **Nunca** configure sudo sem senha por causa disto.

O pacote instala o binário `phasezero-control-center` (atalho *PhaseZero*) e o CLI `pz` (`/usr/bin/pz` → `linux/pz`). A UI só chama `pz` com argumentos de um catálogo fechado; o acesso remoto (SSH) usa `pz` com fallback para `/usr/lib/phasezero/linux/pz`.

Windows: `bootstrap-ui.bat` / `install-cli.bat` no checkout; PowerShell 5.1. Perfis `safe-base` (default) e `full-workstation` (opt-in). Sem `result.json` a corrida é erro do produto. Detalhe abaixo.

---

## Primeiro uso Homelab (o caso deste repositório)

**PC A — appliance** (o outro computador, o que fica ligado)

```bash
phasezero-control-center          # ou: linux/pz ui
# Perfil Servidor / Homelab → Preparar (repair) → Prévia → Ligar
```

Equivalente CLI, sempre com plano primeiro:

```bash
linux/pz server homelab plan --json
linux/pz server homelab repair --access local
linux/pz server homelab apps list --json
linux/pz server homelab apps enable vaultwarden --json
linux/pz server homelab backup
```

Bind default: `127.0.0.1`. Acesso na casa: Tailscale. Restore **nunca** leva `--yes` automático — confirmação em duas etapas.

**PC B — admin** (este computador, o que você usa)

1. Instale o **mesmo** pacote da Release (checksum conferido).
2. Abra o Player → categoria **Homelab**.
3. **Não** clique em “Subir homelab” neste PC. Aqui o papel é administrar o outro.
4. `Host` → adicionar `user@ip-do-appliance` → **Parear** (chave SSH, sem senha no argv).
5. Cards um clique (prévia / ligar / atualizar) e **Abrir dashboard** (HTTPS do appliance).

Primeira conta do dashboard web nasce só no CLI/Player do appliance:

```bash
linux/pz server homelab web user add SEU_USER --password-file ./senha.txt --json
```

A web recusa signup aberto. Cookie: `Secure`, `HttpOnly`, `SameSite=Strict`. Sem CSRF → 403.

---

## Outros casos de uso

### Windows pós-instalação

Máquina limpa, PowerShell 5.1. Perfil default pequeno (`safe-base`). `full-workstation` só por opt-in. A UI WPF e o CLI compartilham o mesmo contrato: log, `result.json`, falha acionável. Reboot pendente bloqueia winget/MSI arriscado.

```text
bootstrap-ui.bat          # painel
install-cli.bat           # CLI
```

### Steam Deck / handheld

Perfil `steamdeck-linux`: Gamepad UI, atalhos, teclado virtual, watcher de dock. Avançado (Handheld Companion / GlosSI) é opt-in porque conflita com Steam Input.

### Windows dentro do Linux (VM)

`pz windows-vm`: ISO que **você** indica. Sem download de ISO/chave. QEMU/KVM, OVMF, TPM 2.0. Detecta domínio libvirt já instalado antes de criar disco.

### Emulação

Launchers e layout `~/Emulation`. BIOS, keys, ROMs: **só importação local** de dumps seus. PhaseZero não baixa ROM/BIOS.

### IA local (proxies, Hermes, 9Router)

Roteamento e proxies no Control Center. Segredos no cofre gerido; stdout JSON sem valores crus. 9Router **recusa** subir se `HOSTNAME`/`PORT` estiverem vazios (não volta a bind `0.0.0.0:3000`).

---

## Limites

O que o produto **não** finge:

- Componente Windows sem prova de auditoria vira `UnsupportedAudit`, nunca “ok”.
- Sem `result.json` a execução é falha do produto, não silêncio.
- Homelab neste PC de desenvolvimento **não** recebe `up` da stack. Appliance é o outro computador.
- BIOS, ROM, ISO e chaves de consola não são descarregados.

## Segurança (o que o leigo precisa saber)

| Tema | Comportamento |
|---|---|
| Imagens Docker | Tags pinadas no lock. Recusa `:latest`. |
| Socket Docker | Só o `socket-proxy` read-only. Nada monta `docker.sock`. |
| Backup | `manifest.json` + SHA-256. Restore verifica; adulterado recusa. |
| Bind | Loopback por omissão. LAN só com opt-in persistido. Sem UPnP. |
| Agente remoto | TLS + token one-shot (15 min). Allowlist. Kill switch local. |
| Dashboard web | HTTPS, CSRF, senha argon2id (scrypt se a lib faltar). 2FA ainda não. |

Documentação profunda: [`docs/linux-homelab.md`](docs/linux-homelab.md) · roadmap [`docs/roadmaps/homelab-umbrelos-parity-v1.md`](docs/roadmaps/homelab-umbrelos-parity-v1.md) · ADRs [`docs/adr/0003-homelab-agent-mdns.md`](docs/adr/0003-homelab-agent-mdns.md) e [`docs/adr/0004-homelab-web-dashboard.md`](docs/adr/0004-homelab-web-dashboard.md).

---

## CLI rápido (quando o painel não chega)

```bash
linux/pz help
linux/pz ui                          # Control Center
linux/pz server homelab status --json
linux/pz server homelab hosts add garage 'user@192.168.1.8' --json
linux/pz server homelab --host garage apps list --json
linux/pz server homelab discover --json
```

Catálogo completo de ações: a própria UI e `linux/ui/actions.json` (gerado, não editar à mão).

---

## Desenvolvimento e testes

CI (`.github/workflows/ci.yml`): parse PowerShell, Pester 3.4.0, ShellCheck 0.9 e 0.11, pytest, compose validate, gitleaks. Docker **só** em jobs descartáveis (`PZ_HOMELAB_APPS_DISPOSABLE=1` + estado em `/tmp` ou `RUNNER_TEMP`). O runner genérico **não** executa esses scripts.

Release canónica:

```bash
packaging/release.sh 1.19.0 --push    # bump, tag anotada, dispara o workflow
```

Tags históricas **não** se movem. Confira sempre o `SHA256SUMS` da versão que vai instalar.

---

## Licença e âmbito

PhaseZero não substitui o instalador do Windows nem o umbrelOS. Não distribui ISOs, ROMs, BIOS nem chaves de consola. Contribuição de apps Homelab: PR no catálogo do repositório, não loja comunitária.
