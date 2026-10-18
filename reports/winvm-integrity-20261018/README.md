# Windows VM: integrity observations and dynamic storage

## Problem and cause

Two installation entries were labelled completed, without a current integrity
observation. Completion comes from the provisioning worker; its old verification
only checked image length. This cannot prove Windows health. The displayed size
was allocated staging storage, but the UI did not explain its components or the
difference from guest capacity.

Both real operations have 256 GiB virtual capacity, already using growable QCOW2.
Observed allocation, without deleting or converting anything:

| Operation | Base | Snapshot | Media | Staging total | Separate activated copy |
|---|---:|---:|---:|---:|---:|
| op-20260923-225352-18359 | 17.3 GiB | 21.7 GiB | 753.5 MiB | 39.8 GiB | 36.0 GiB |
| op-20261015-224232-10324 | 18.5 GiB | 22.2 GiB | 753.5 MiB | 41.4 GiB | none recorded |

These are allocated blocks, not an advance reservation of 40 GiB. A snapshot
retains old blocks while later writes allocate new blocks. Activation also makes
a standalone copy. The existing removal workflow for installation files does
not remove that activated copy. No layer may be deleted merely because it looks
redundant: an overlay may depend on its base. Deleting files inside Windows need
not return space to the host, especially with retained snapshots.

## Implementation

`linux/windows-vm/storage.py` owns read-only accounting and bounded probes.
The public CLI resolves operation IDs through the existing validated inventory:

```bash
pz windows-vm provision inventory --json
pz windows-vm provision integrity --operation-id OPERATION_ID --json
pz windows-vm provision integrity --operation-id OPERATION_ID --guest-files --json
```

The inventory stays cheap and reports `not-checked`; no heavy scan starts on
status/login/UI load. The explicit check validates supported local QCOW2 files,
the expected backing relation, `qemu-img check` without repair, and optionally
essential Windows files through `guestfish --ro --format=qcow2 -i`. Guestfish
uses an isolated inspection appliance; the installed Windows never executes
and no guest filesystem is mounted on the host. Only booleans and missing-file
names are returned, never guest registry/file contents or raw subprocess output.

Live QEMU blocks the check conservatively because images can share backing
files. No force-sharing flag is used. Missing files, invalid format, broken chain,
QCOW2 corruption/leaks, inaccessible dependencies, invalid replies, timeouts,
partial installations and concurrent changes have distinct observations.
Timeout cleanup targets only the probe's own new process group. Image identity,
size, mtime and ctime are rechecked before accepting the observation.

Exit 0 means a diagnostic document was produced, not that Windows is healthy:
inspect `state`, per-image results, `windowsFiles`, `completionRecorded` and
`bootVerified`. Invalid/missing operation selection exits nonzero. No repair,
conversion, resize, discard, mount or deletion is performed.

The UI exposes one explicit **Verificar integridade** button, observed state,
reason when available, next step, capacity and allocation breakdown. Advanced
mode includes timestamp, source, paths and diagnostic JSON. Actions remain
disabled while checking or when a VM is running. Existing trash/typed purge
confirmations remain; an inconclusive result explicitly discourages disposal.
New image creation explicitly uses `preallocation=off`; existing images need
no migration to become dynamic.
Both boot-runtime manifests include the new Python dependency, so a packaged
runtime remains self-contained when the development checkout is unavailable.

## Evidence and limits

`host-first.json` and `host-second.json` record real read-only checks on
misael-jupiter, BigLinux/Manjaro, installed PhaseZero 1.22.7-1. All five images
(two bases, two overlays and the first operation's activated copy) returned
`qemu-img check` exit 0. Essential SYSTEM/SOFTWARE registry hives, kernel and
winload.efi were present in each inspected operational image. Both observations
have `bootVerified:false`; no evidence here establishes an incomplete Windows
installation or permits automatic deletion. Filesystem cleanliness, full file
checksums, successful boot and functional guest health remain unproved.

Local baseline: 55 Qt tests passed before edits. Focused regression: 84 passed;
provisioning suite: 259 passed, zero failed. Theme probes exercise the public
button with actual host observations; backend checks are independently real.
Captures under `ui/`: Xvfb parent 800×600 and actual KDE parent 800×568 (screen
availability), inventory 780×540, light/dark, no horizontal overflow or clipped
actions. No screen resolution or KDE session change was made by this task.
Other shell/package/CI gates and installed-package evidence accompany the PR
and release delivery receipt; they must pass before publication/install claims.

Local harness pitfalls encountered: the existing shell suite rejects `/home/`
inside a fixture path, reproduced on clean main; long TMPDIR also exceeds Unix
socket limits. Use short disk-backed `/var/tmp/pzi`, not the live runtime tmpfs.
The graphics suite also read the host USB tree: a real Deck controller changed
the dry-run from expected fake virtio input to USB passthrough. Reproduced on
clean main; the fixture now explicitly uses an empty USB sysfs directory.
An intervening host session interruption left SD-card directory entries that
list but fail lookup and some unpersisted writes. Cause is not established.
Eleven known task files were preserved on SSD with a checksum manifest at
`~/.local/state/phasezero/winvm-integrity-recovery-20261018`. A fresh independent
repository and dedicated worktree on SSD continue the task; the original
checkout and all parallel WIP remain intact. No mounted-filesystem repair ran.

Display change `3302a3b` is represented in main by its integrated successor
`2f5f262` (PR #60, including the `9e06323` work); active refresh propagation also exists. This patch changes no
display contract. Physical GRUB/display/shutdown gates from WBR remain open;
no VM was adopted as primary or booted to close those unrelated gates.

## Contract sources

- [Official QEMU image utility](https://www.qemu.org/docs/master/tools/qemu-img.html):
  virtual versus actual allocation, sparse images, check return codes and the
  warning against modifying images in use.
- [Official guestfish manual](https://libguestfs.org/guestfish.1.html): readonly
  appliance inspection and automatic inspection with `-i`.

## Handoff

```text
Objetivo da sessão: integridade observada e espaço dinâmico WinVM, PR/release/host.
Fase/IDs assumidos: WBR-009/010; publicação pela Fase 10 Homelab.
Branch e worktree: codex/winvm-integrity-sparse, worktree SSD informado acima.
HEAD inicial: bbee41c (main/release 1.22.7).
HEAD final: ver PR e recibo da entrega, sem antecipar SHA de publicação.
Arquivos alterados: storage.py, provision/windows-vm shell, gerenciador de imagens,
  introdução do instalador, testes Qt/QCOW2, CI qemu-utils, docs e changelog.
Commits criados: ver histórico do PR, uma responsabilidade por commit.
Testes executados e resultados: evidência acima; CI completa obrigatória.
CI/PR: link e SHA exato no PR/recibo; publicar somente com gates verdes.
Estado do host antes/depois: antes 1.22.7-1; discos preservados; depois no recibo.
Segredos verificados como ausentes: sem conteúdo guest/log bruto; scan no CI.
Limitações e riscos restantes: nenhuma prova de boot/NTFS/saúde completa.
Bloqueios reais: publicação e instalação dependem dos gates; storage SD inconsistente.
Próximo passo exato: CI verde, merge, release canônica, checksums, pacote oficial,
  validar UI e diagnóstico instalado; nunca apagar VM como parte da atualização.
```
