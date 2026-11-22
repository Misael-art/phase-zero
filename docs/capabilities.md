# Capabilities Linux

Contrato: `pz.capabilities/v1`.

## Fluxo

```text
detect → catalog/status → plan → apply → verify → rollback
```

- `detect`: fatos do host; nenhuma mutação.
- `catalog`: recursos, compatibilidade e fonte preferida.
- `status`: inclui presença instalada.
- `plan`: expande perfil/dependências, valida conflitos e disponibilidade, persiste preview privado e gera token.
- `apply`: exige ID + token; revalida host/fonte antes de executar.
- `verify`: consulta fontes e serviços registrados pela operação.
- `rollback`: exige token próprio e atua somente sobre mudanças registradas pela operação.

## Manifesto

JSON máximo 256 KiB, arquivo regular, sem symlink:

```json
{
  "schema": "pz.capabilities/v1",
  "description": "Minha workstation",
  "profiles": ["gaming-core", "developer"],
  "capabilities": ["backup.rclone"],
  "policy": {"maxRisk": "elevated", "allowReboot": false}
}
```

Campos desconhecidos falham. IDs desconhecidos falham. Dependências são ordenadas antes do consumidor. Conflitos selecionados bloqueiam o plano.
`maxRisk` limita risco agregado; `allowReboot: false` bloqueia recursos que recomendam ou exigem reinicialização. Planos expiram após 24 horas.

## Segurança

- Providers: pacote assinado da distribuição ou Flatpak/Flathub já configurado.
- Sem `curl | shell`, AUR automático, `eval` ou shell construído por entrada.
- Argumentos seguem vetores argv.
- Aplicação elevada usa bridge PhaseZero/PolicyKit.
- Estado alvo respeita usuário original após elevação.
- Diretórios `0700`; registros `0600`; escrita atômica.
- Saída limitada e diretório pessoal redigido.
- Pacotes preexistentes nunca entram na lista de rollback.
- Ativação de serviço permitida somente por receita fixa e reversível.
- Firewall, rede, boot/kernel e autenticação remota permanecem ações avançadas explícitas.

## Portabilidade

Catálogo separa compatibilidade, fonte e provider. Linux oferece Arch, Debian, Fedora, openSUSE e fallback Flatpak. Sistemas imutáveis preferem Flatpak e bloqueiam drivers incompatíveis. UI filtra por `platforms`; implementação Windows futura pode adicionar providers sem misturar chamadas Unix na camada visual.

## Boot dinâmico de ISOs

Contrato específico: `linux/pz boot iso|usb|grubfm`.

- Na Central Linux, abra **Boot Direto → Testar distros** e escolha uma ISO. A
  prévia informa o perfil detectado e o arquivo que vai ser usado. Confirme e
  autorize a gravação da entrada. Na próxima inicialização, escolha a
  distribuição no menu do GRUB. A remoção pela mesma página preserva o arquivo.
- A detecção cobre BigLinux/Manjaro com layout MISO, Arch Linux, SystemRescue,
  Ubuntu e derivados com Casper, Debian Live e Grml. Preserve a localização
  da ISO para iniciar a sessão. Imagens sem perfil compatível são recusadas.
- `iso inspect/scan/status`: read-only; identifica somente layouts conhecidos.
- `iso add/remove/install`: manifesta ISO por UUID, caminho GRUB, perfil e SHA-256. A Central vincula a confirmação ao hash da prévia. A gravação confere a sintaxe e a presença das entradas no GRUB.
- `usb discover/status`: inventaria mídia removível.
- `usb add/remove/install`: registra `/EFI/BOOT/BOOTX64.EFI` por UUID; nunca persiste `/dev/sdX` ou `(hdN,gptN)`.
- `grubfm inspect/status`: audita payload EFI local.
- `grubfm install/remove`: experimental, exige SHA-256 explícito, upstream arquivado e Secure Boot desativado; sem download automático.
- `boot choose iso:<id>|usb:<id>|grubfm`: agenda somente próximo boot via `grub-reboot`.

Scripts gerados usam slots `46`–`48`, preservando entradas PhaseZero existentes. Mutação exige bridge admin, backup prévio, escrita atômica, `grub-mkconfig -o /boot/grub/grub.cfg`, validação de IDs e rollback em falha. ISO/EFI do usuário nunca é removido por rollback.
