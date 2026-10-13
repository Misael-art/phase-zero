# ADR 0004: dashboard web Homelab (sessão, CSRF, senha)

- Status: aceito
- Data: 2026-08-26
- Escopo: serviço web no host Homelab (appliance); botão "Abrir dashboard" no Player
- Bloqueia: código do dashboard web (HL-WEB-001)

## Contexto

umbrelOS é gerido no browser (`umbrel.local`). PhaseZero já tem Player no host
admin. A Fase 4 acrescenta um dashboard no appliance para qualquer dispositivo
da LAN. É a maior superfície nova desta frente: cookies, CSRF, senha, restore.

O host de desenvolvimento não corre este serviço. Docker e bind WAN continuam
proibidos fora de CI descartável.

## Decisão

1. **Onde corre.** Processo no host homelab, HTTPS obrigatório, certificado
   próprio (pode reutilizar o do agente). Bind default `127.0.0.1`. Bind LAN
   só com opt-in persistido (`lanBind: true`). Sem UPnP, sem port-forward.
   Fora de casa o caminho continua Tailscale.
2. **Contas.** Utilizadores LOCAIS geridos por
   `pz server homelab web user add|remove|password` e pelo Player. Hash
   argon2id. Senha fraca recusada. A primeira conta **nunca** nasce pela web
   aberta: bootstrap só CLI/Player. Web sem users → recusa signup.
3. **Sessão.** Cookie `Secure`, `HttpOnly`, `SameSite=Strict`, expiração
   curta. CSRF token obrigatório em mutações. Sem cookie/CSRF → 403.
4. **Ações.** Paridade com o Player: status, cards, up/down, backup, logs,
   restore assistido em duas etapas. Restore na web **nunca** envia `--yes`.
5. **Player.** Botão "Abrir dashboard" abre a URL HTTPS do host selecionado
   (local ou `--host`).
6. **Segredos.** Nunca em HTML, logs ou query string. Scan gitleaks verde.

## Ameaças e mitigações

| ameaça | mitigação |
|---|---|
| Dashboard na WAN | bind loopback; LAN opt-in; Tailscale para externo |
| Signup aberto | zero users → recusa; bootstrap local |
| Sessão roubada | HttpOnly+Secure+SameSite; TTL; CSRF |
| Restore cego | duas etapas; nunca `--yes` |
| Senha fraca | política no `web user add/password` |
| XSS no log viewer | escape; Content-Type; CSP básica |

## Consequências

Implementação só depois deste ADR e de testes de contrato que falhem
(login sem CSRF, cookie sem flags, restore sem confirmação, bind `0.0.0.0`
sem opt-in). 2FA permanece deferred.
