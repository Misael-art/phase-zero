# PhaseZero: continuidade antes e depois da reinstalação — 2026-10-21

Estado: **pré-formatação; escopo dos volumes ainda precisa ser confirmado**. Este documento contém caminhos e checks, não senhas. Revalidar tudo no novo host. Fonte atual: `https://github.com/Misael-art/phase-zero.git` (pública), `main` `ddadd6de4fc5a0b8933c2d312e2f8a6dd7f1aff3`, release beta `v1.22.11`; pacote instalado no host antigo `phasezero-control-center 1.22.11-1`.

## Risco físico e limites do resgate

- Host antigo `misael-jupiter`: NVMe `/dev/nvme0n1p2` Btrfs, 98% ocupado, 23 GiB livres; `btrfs device stats /` retornou **6741 `corruption_errs`** em 2026-10-21. Fazer cópia antes de qualquer formatação; verificar leituras e hashes. Erro Btrfs não prova qual arquivo foi afetado.
- Cartão separado `/dev/mmcblk0p1`, NTFS montado em `/mnt/sdcard`, tinha 183 GiB livres antes do resgate. **Se também será formatado, copiar seu conteúdo para outra mídia antes.** Cópia no mesmo cartão que abriga os worktrees não é segunda cópia independente. NTFS montado ignora `chmod`: arquivos do resgate apareceram com modo 777; dados privados exigem arquivo criptografado e guarda física.
- Nenhum processo QEMU observado; VM local ocupa ~53 GiB. Pasta: `~/VirtualMachines/PhaseZero-Windows-20260923-225352-18359`, inclui `phasezero-windows.qcow2`, `OVMF_VARS.fd` e estado TPM. **Decisão do usuário em 2026-10-21: a VM atual é descartável; não bloquear a formatação por falta de backup dela.** O código PhaseZero e o pacote da release não dependem dessa imagem. Descartá-la elimina o Windows configurado, arquivos e snapshots do guest; eventual ativação/licença, ISO e credenciais precisam ser obtidas novamente. Se a decisão mudar, preservar imagem + OVMF + TPM juntos, conferir checksums e `qemu-img check` antes do boot.
- Estado pessoal opcional fora do Git: `~/.config/phasezero`, `~/.local/share/phasezero` (~2,7 GiB), `~/.local/state/phasezero` (~4,9 GiB, inclui estado Windows VM), `~/.config/systemd/user`, `~/.local/share/ai-memory` (~1,1 GiB; SQLite com WAL ativo), `~/.hermes` (~7,6 GiB), `~/.codex` (~35 GiB), `~/.config/Claude` (~3,5 GiB), autenticações/SSH e perfis de navegador relevantes. Não é necessário para reinstalar o **código** PhaseZero; sem backup, serviços e contas começarão do zero. Credenciais não devem entrar no repositório público. Algumas sessões dependem de cofre/chave do sistema antigo e precisarão de novo login mesmo após copiar arquivos.
- Estado privado do host ainda não está no GitHub. Para retomada **do código** a partir de `main` e dos PRs remotos, a VM e esses perfis não são requisitos. Para retomar sessões, configurações e contas sem reconfigurar, é necessário backup privado criptografado e verificado. Não chamar essa retomada de “sem perdas” se estado local for descartado.

## Código já remoto

| Frente | Ponto de retomada | Prova/limite |
|---|---|---|
| Base | `main` `ddadd6d`, release `v1.22.11` | Clone da origem pública; conferir SHA/tag antes de instalar |
| DeepSeek Harness | [PR #127](https://github.com/Misael-art/phase-zero/pull/127), `codex/deepseek-harness-integration` `336abb7` | Draft; CI Arch/Windows, Pester, shell/Python e secret scans verdes; sem instalação nem conta real no host. Ler `docs/roadmaps/deepseek-harness-implementation-handoff.md` nessa branch |
| Plano Harness | [PR #126](https://github.com/Misael-art/phase-zero/pull/126), `codex/deepseek-harness-plan` `eda2ca9` | Draft; roadmap DSH-001..010 |
| Windows VM | [PR #116](https://github.com/Misael-art/phase-zero/pull/116), `fix/winvm-ram-rebase` `f7fcdf7` | Aberto; ler roadmap WinVM e revalidar físico |
| Handoff WinVM | [PR #115](https://github.com/Misael-art/phase-zero/pull/115), `docs/handoff-20261013` `6c6946a` | Aberto |

PRs, commits e CI são evidência de código, não prova de restauração do host. Consultar estado vivo no GitHub depois da reinstalação.

Verificação adicional em 2026-10-21: tag `v1.22.11` resolve para `ddadd6de4fc5a0b8933c2d312e2f8a6dd7f1aff3`, igual à `main` remota. Pacote Arch baixado da release, `phasezero-control-center-1.22.11-1-any.pkg.tar.zst`, SHA-256 `586beba73bfe9aafd20ad2297ea0e1bc20a084625b2ea925a649d9c0577378af`, coincide com `SHA256SUMS-1.22.11` e com o digest publicado. `.PKGINFO` declara `pkgver = 1.22.11-1`, `arch = any` e dependências `python`, `pyside6`, `bash`, `jq`, `polkit`. Cópia offline conferida em `/mnt/sdcard/PhaseZero-preformat-20261021/release-verification-v1.22.11/`. Isso prova integridade do artefato baixado, não instalação limpa neste host após a formatação.

## Código ainda só local em 2026-10-21

Inventário: 17 worktrees. O checkout principal tinha 79 arquivos modificados, **somente diferenças de fim de linha** (`git diff --ignore-space-at-eol` e `git diff -w` vazios); não há alteração semântica detectada. Outras frentes:

- `codex/bonsai-launcher-recovery` `c97c1e9`: **2 commits ausentes do remoto** + 9 arquivos modificados; não mover nem commitar WIP de outro agente às cegas.
- `codex/winvm-integrity-sparse` `bbee41c`: 6 arquivos modificados + 6 novos, incluindo `linux/windows-vm/storage.py` e testes/relatórios; nada disso foi publicado.
- `fix/deck-controller-session-binding` `a2c3d20`: 2 arquivos modificados + 5.321 entradas não rastreadas. 5.316 são ledger `.mimosa` (~40 MiB); há 3 docs, `.zcodeignore` e repositório privado aninhado `uber-defesa-privada` (~84 MiB). Não publicar repositório privado no PhaseZero público.
- Outros refs locais não presentes em `origin`: `codex/homelab-appliance`, `codex/verify-pr1`, `codex/winvm-provision-recovery`, `integration/validate-20261013`. Não assumir que são trabalho aceito; conservar para inspeção.

Resgate local criado em `/mnt/sdcard/PhaseZero-preformat-20261021/code-20261021T142735`: bundle com 330 refs, tar do `.git`/reflogs, patches binários e tar dos untracked. Nove artefatos somam 145.813.134 bytes; hashes de todos re-lidos e `git bundle verify` passaram. SHA-256 de `manifest.json`: `16b0590d59dbca9d8842665c8f2bc04bc01780d9087470fdf9b43537ac4816e5`. **Backup local no cartão, não no GitHub; contém dados privados; ainda não autoriza apagar cartão.** Após qualquer trabalho concorrente, repetir inventário e resgate antes de formatar.

## Ordem no novo sistema

1. Montar mídia de resgate **somente leitura** inicialmente. Confirmar UUID esperado e SHA-256 do manifesto; conferir cada artefato contra `manifest.json`. Não executar scripts diretamente do backup.
2. Configurar Git e acesso GitHub; `git clone https://github.com/Misael-art/phase-zero.git`. Verificar `git remote -v`, `git rev-parse HEAD`, `git ls-remote origin refs/heads/main` e tags. Criar worktrees separados por frente; nunca aplicar patches sobre `main` limpo.
3. Inspecionar bundle com `git bundle verify`; recuperar apenas refs locais necessários em clone descartável. Para cada patch, conferir branch/HEAD no manifesto, rodar `git apply --check --binary`, depois aplicar. Inspecionar caminhos do tar dos untracked antes de extrair. Não fazer push de WIP/segredos sem revisão.
4. Restaurar backup privado criptografado, se produzido. Para ai-memory: usar cópia SQLite consistente, verificar `PRAGMA integrity_check`, depois conferir wiki/handoff. A VM atual foi declarada descartável: reinstalar o Windows por ISO fornecida pelo usuário quando houver recursos; PhaseZero não distribui a ISO nem a licença. Se uma imagem tiver sido preservada por decisão posterior, restaurar imagem, OVMF e TPM juntos e conferir checksum/`qemu-img check` antes de iniciar.
5. Seguir instalação oficial do [README](../../README.md): baixar artefato da Release e `SHA256SUMS` correspondentes, verificar `sha256sum -c`; instalar pacote adequado à distribuição. Em Arch, pacote pacman. No host limpo, preparar `pz ai setup admin` só após pacote presente. Não reinstalar runtime manualmente em `/usr/lib/phasezero`.
6. Validar `pz --version`, `pz ai admin status`, UI, catálogo/ações, estado Homelab/WinVM/IA, permissões e serviços de usuário. Reabilitar serviços um por vez; relogar contas cujo token não é portátil. Não iniciar Homelab/VM/DeepSeek Harness pesado automaticamente.
7. Rodar testes afetados e CI por SHA final; registrar resultado real Arch/Windows/host. PR #127 continua Experimental até gates de conta real, sandbox e usabilidade; não marcar como release completa por passar CI descartável.

## Gate objetivo para autorizar formatação

- Para **retomar somente o código já no GitHub**, clonar `main`/release e buscar PRs remotos basta. Isso não inclui PRs não mergeados na release nem alterações locais sem push.
- Para **retomar todo o desenvolvimento local PhaseZero**, preservar `/mnt/sdcard` sem formatar **ou** copiar o resgate, worktrees e alterações posteriores para mídia fora de todos os volumes que serão apagados; verificar hashes e `git bundle verify`. O resgate feito no próprio SD não protege contra a formatação do SD.
- VM atual: **backup dispensado por decisão explícita do usuário**. Registrar perda aceita de guest, arquivos, snapshots e estado de ativação; instalar guest novamente a partir de ISO/licença obtidas separadamente, se necessário.
- Estado privado (`ai-memory`, contas, credenciais, configurações e sessões) é escolha distinta. Sem backup criptografado e verificado, a retomada será uma configuração nova, com novos logins e sem histórico local. Backup necessário apenas se a preservação desse estado for requisito.
- Confirmar exatamente quais volumes serão formatados e quais permanecerão intactos. Nenhum item pendente tratado como “preservado”.

## Handoff da sessão

Objetivo: permitir reinstalação sem perder desenvolvimento PhaseZero. Estado em 2026-10-21: código remoto verificado, resgate de Git no SD validado; usuário dispensou backup da VM atual. Preservação de estado privado e destino independente dependem do escopo real da formatação. Nenhum reboot, limpeza, mudança de pacote/serviço ou VM executado. Próxima ação: confirmar escopo dos volumes, repetir snapshot de WIP concorrente e preservar qualquer dado local situado em volume que será apagado; depois executar checklist do novo sistema.
