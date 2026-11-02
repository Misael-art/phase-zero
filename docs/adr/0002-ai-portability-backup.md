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

## Extensão: automação e múltiplos hosts (2026-11-01)

O envelope automático também usa OpenPGP AES-256/S2K SHA-512. Uma chave aleatória
por conjunto de memória fica no Secret Service/Windows Credential Manager já
existente; configuração contém apenas referência opaca. Cofre indisponível
bloqueia operação, sem fallback para arquivo. Exportação da chave de recuperação
exige senha por stdin e gera pacote OpenPGP separado. Importação em outro host
vincula o mesmo conjunto sem copiar identidade do equipamento.

Backup integral e conhecimento compartilhado têm contratos diferentes. Backup
usa snapshot nativo consistente, histórico bruto complementar e configuração
externa dentro do envelope criptografado. Credenciais de provedores e sessões
de navegador ficam fora da automação. Conhecimento usa companion oficial
`ai-memory-wikisync`, famílias e projetos explicitamente cadastrados, escritas
condicionais e conflitos preservados. Não se mesclam bancos SQLite nem se faz
pull/merge Git na wiki ativa. Metadados de transporte não substituem origem e
datas históricas dos registros.

Mídias precisam de cadastro e identidade de volume; arquivos publicados são
imutáveis e verificados antes do manifesto de conclusão. GitHub usa repositório
dedicado privado, identidade fixada, conteúdo criptografado e autenticação
existente do GitHub CLI. Conhecimento pequeno usa Git; snapshots integrais usam
assets de releases do repositório de memória, sem alterar releases PhaseZero.
Privacidade e identidade são revalidadas antes de cada publicação. Exclusões
de conhecimento nunca são propagadas automaticamente. Restauração exige plano,
pré-backup e ciclo coordenado do serviço; reparar nunca apaga memória.

