# ADR 0002: backup portátil de memória e autenticação de IA

- Status: aceito
- Data: 2026-08-24
- Escopo: host Linux PhaseZero

## Contexto

Reinstalação do host pode perder memória semântica do `ai-memory`, chaves de
provedores e autenticações de clientes. Cópia ampla de `$HOME`, perfis de
navegador ou cookies criaria exposição excessiva e restauração imprevisível.

## Decisão

PhaseZero oferece pacote portátil com estas propriedades:

1. Memória exportada pelo comando nativo `ai-memory backup`.
2. Credenciais somente com opção explícita `--include-credentials` e allowlist
   fixa. Perfis de navegador, cookies e sessões Playwright ficam excluídos.
3. Envelope OpenPGP simétrico com AES-256, S2K iterado SHA-512 e proteção de
   integridade. Senha entra por stdin; nunca por argumento, log ou manifesto.
4. Manifesto contém apenas paths relativos, categoria, modo e SHA-256. Nunca
   valores de segredo.
5. Verificação descriptografa em diretório temporário, rejeita paths absolutos
   ou `..` e compara todos os hashes antes de considerar o pacote válido.
6. Restauração sempre possui `--plan`, faz backup prévio da memória e dos
   arquivos existentes e tenta rollback se qualquer aplicação falhar.
7. Destino existente, symlink ou path amplo é recusado. Pacote final recebe
   modo `0600`; temporários recebem `0700` e são removidos por trap.

## Allowlist de credenciais

- `~/.config/phasezero/ai-proxies/*.env`
- `~/.config/phasezero/ai-providers/mimo/api-key`
- `~/.config/phasezero/ai/hermes.env`
- `~/.local/share/opencode/auth.json`
- `~/.codex/auth.json`
- `~/.claude/.credentials.json`
- `~/.config/ai.z.zcode/store.json`

## Consequências

Pacote depende de GnuPG e da função nativa de backup/restore do `ai-memory`.
Senha esquecida torna o pacote irrecuperável. Sessões de navegador precisam de
novo login após reinstalação; decisão intencional para não transportar cookies.

