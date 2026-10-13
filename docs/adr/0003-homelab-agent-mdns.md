# ADR 0003: agente Homelab TLS+token e descoberta mDNS

- Status: aceito
- Data: 2026-08-26
- Escopo: host Homelab (appliance) e Player no host admin
- Bloqueia: implementação do daemon `phasezero-agent` (HL-AGT-004)

## Contexto

A Fase 2 opera o appliance via SSH. A Fase 3 quer a experiência umbrel-like:
descobrir o homelab na LAN e parear sem terminal. O agente é um alvo na rede
local. `os-slim.sh` pode desligar avahi em host headless.

Papéis (decisão 0 do roadmap umbrelOS-parity v1):

- Appliance: corre o agente, anuncia mDNS, nunca recebe docker.sock no agente.
- Admin: Player descobre, cola o token, revoga. Registro SSH da Fase 2
  permanece como fallback.

## Decisão

1. **Processo.** `phasezero-agent` é um serviço `systemd --user` do usuário
   dono do runtime Homelab. Nunca root, nunca docker.sock, nunca shell
   arbitrário. Cada pedido da allowlist invoca `linux/pz` do usuário com
   argv explícito (`shell=False`).
2. **Transporte.** HTTPS obrigatório. Certificado auto-assinado gerado no
   appliance, gravado em `$XDG_STATE_HOME/phasezero/homelab-agent/` modo
   `0600`. Bind default `127.0.0.1`; LAN (`0.0.0.0` em interface local)
   só com opt-in persistido. Sem UPnP, sem port-forward.
3. **Pareamento.** Token aleatório (≥128 bits) exibido **uma vez** em
   `pz server homelab agent install|pair`. Armazenado só como SHA-256.
   Expira em 15 minutos ou no primeiro uso. `POST /v1/pair` consome o
   token e emite um token de sessão (também hashed). Sem token, token
   expirado ou já consumido → 401.
4. **Sessão e revogação.** Sessões em `sessions.json` (`0600`).
   `revoke` apaga a sessão (e o pairing residual). Pedido seguinte com
   o token revogado → 401. Kill switch: presença de `agent.kill` recusa
   tudo com 503.
5. **Allowlist fechada.** Nomes de comando, não strings livres:

   | nome | argv |
   |---|---|
   | `status` | `server homelab status --json` |
   | `plan` | `server homelab plan --json` |
   | `apps.list` | `server homelab apps list --json` |
   | `apps.enable` | `server homelab apps enable <app> --json` |
   | `apps.disable` | `server homelab apps disable <app> --json` |
   | `apps.update` | `server homelab apps update <app> --json` |
   | `backup` | `server homelab backup --json` |
   | `restore.plan` | `server homelab restore --source <path> --plan` |

   `restore` com `--yes` é recusado. Qualquer outro nome, metacaractere,
   espaço ou `sh -c` → 403 e linha de auditoria.
6. **Rate limit.** 20 pedidos / 60 s por IP; 5 falhas de auth / 60 s → 429.
7. **Auditoria.** `audit.log` append-only (`0600`): timestamp, IP, ação,
   resultado. Nunca token, nunca senha, nunca stdout bruto de `pz` se
   contiver segredo (passa pelo redator existente quando houver).
8. **mDNS.** Serviço `phasezero-homelab._tcp`. Se avahi estiver ausente
   ou mascarado (os-slim), `discover` devolve orientação e
   `wouldReenableAvahi:false`. Fallback permanente: `IP:porta` manual.
   Instalação do agente **não** reativa avahi.
9. **CLI.** `pz server homelab agent install|uninstall|status|pair|revoke --json`
   e `pz server homelab discover --json`. stdout JSON, logs stderr.

## Ameaças e mitigações

| ameaça | mitigação |
|---|---|
| Scanner na LAN sem token | TLS + 401; rate limit; sem banner de versão no `/` |
| Token de pairing reutilizado | one-shot + hash + TTL 15 min |
| Replay de sessão | revogação; kill switch local |
| Injeção de shell no campo comando | allowlist de nomes; argv fixo; `shell=False` |
| Agente como proxy de docker.sock | nunca monta o socket; só `pz` do user |
| os-slim vs avahi | detectar, orientar, nunca reativar |
| Token em logs/UI | hash no disco; redacção; um print |
| Bind 0.0.0.0 acidental | default loopback; opt-in persistido |

## Consequências

Admin ainda pode usar o bridge SSH da Fase 2 se o agente estiver morto.
Certificado auto-assinado exige TOFU no Player (fingerprint no `discover`
e no `status`). 2FA fica deferred. Sem este ADR, código do agente não
avança (HL-AGT-004).
