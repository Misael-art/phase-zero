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

## Pastas virtuais do Google Drive no Linux

Pessoa abre **Central → Recursos → Backup e nuvem**, autoriza uma conta
no navegador e escolhe uma pasta do Drive e um diretório local. A pasta
montada abre no gerenciador de arquivos e fica registrada ao reabrir a Central.
Cada montagem usa uma conta. Contas e montagens podem coexistir e as cotas
continuam independentes.

Plano de implementação:

1. Reutilizar `backup.rclone` para preparar o rclone e detectar FUSE no host.
2. Usar OAuth no navegador pelo rclone. Validar a identidade da conta no Google
   antes de salvar ou renovar a conexão. Oferecer leitura por padrão e edição
   quando autorizada.
3. Listar as pastas do Drive, salvar a escolha e montar em um diretório vazio
   como usuário da sessão. Consultar o estado no kernel, abrir a pasta no
   gerenciador de arquivos e bloquear desmontagem durante gravações.
4. Validar autorização, cancelamento, duas contas, múltiplas pastas, envio,
   desmontagem e reabertura. Registrar os gates que exigem uma conta real.

O responsável pela instalação abre **Configurar autorização Google** uma vez.
A janela leva à ativação da Google Drive API e à criação do
[cliente OAuth Desktop](https://rclone.org/drive/#making-your-own-client-id)
no mesmo projeto. Importe o JSON baixado em **Importar JSON…**.
Para um piloto, configure o público de teste no Google Cloud. Para distribuição,
siga os [requisitos de verificação dos escopos do
Drive](https://developers.google.com/workspace/drive/api/guides/api-specific-auth).

Quando o consentimento termina e o Google informa que a API do Drive está
desativada, a Central exibe **Ativar API do Drive**. Ative a API no projeto
indicado e volte a **Conectar conta**.

**Conectar conta** abre o navegador padrão. O modo edição pede acesso de
leitura e escrita ao Drive. Operações feitas na pasta montada afetam os
arquivos na nuvem. Mesmo com uma conta autorizada para edição, cada pasta
pode ser montada somente para leitura. A edição exige rclone 1.68 ou superior.
Os tokens ficam na configuração privada do rclone, em
`$XDG_CONFIG_HOME/phasezero/cloud-drive` (padrão `~/.config`). A autorização
pode ser revogada nas permissões da conta Google.

Montagens usam a sessão Linux e sobrevivem ao fechamento da Central. Após
reiniciar o computador, selecione **Montar** para recuperar a mesma pasta e
retomar envios pendentes. O modo edição mantém cache persistente em
`$XDG_STATE_HOME/phasezero/cloud-drive` (padrão `~/.local/state`), com meta
de 2 GiB por montagem. Arquivos abertos ou aguardando envio podem ultrapassar
essa meta. Use **Desmontar** e aguarde a confirmação antes de desligar.
Ao montar pastas em edição, escolha origens distintas. Alterações simultâneas
nos mesmos arquivos podem conflitar, inclusive por atalhos e aplicativos externos.

Os mesmos comandos estão em `pz cloud-drive --help`.

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

- `iso inspect/scan/status`: read-only; identifica somente layouts conhecidos.
- `iso add/remove/install`: manifesta ISO por UUID, caminho GRUB, perfil e SHA-256; toda escrita recompila e valida GRUB.
- `usb discover/status`: inventaria mídia removível.
- `usb add/remove/install`: registra `/EFI/BOOT/BOOTX64.EFI` por UUID; nunca persiste `/dev/sdX` ou `(hdN,gptN)`.
- `grubfm inspect/status`: audita payload EFI local.
- `grubfm install/remove`: experimental, exige SHA-256 explícito, upstream arquivado e Secure Boot desativado; sem download automático.
- `boot choose iso:<id>|usb:<id>|grubfm`: agenda somente próximo boot via `grub-reboot`.

Scripts gerados usam slots `46`–`48`, preservando entradas PhaseZero existentes. Mutação exige bridge admin, backup prévio, escrita atômica, `grub-mkconfig -o /boot/grub/grub.cfg`, validação de IDs e rollback em falha. ISO/EFI do usuário nunca é removido por rollback.
