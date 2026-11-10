#!/usr/bin/env bash
# Provision the Vibe Code tools and an opt-in Plasma boot entry.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

action="${1:-status}"
shift || true
boot_id=phasezero-vibe-code
grub=/boot/grub/grub.cfg
generator=/etc/grub.d/46_phasezero_vibe_code
root_config=/etc/phasezero/vibe-code.conf
session_helper=/usr/local/lib/phasezero/vibe-code-session
unit=/etc/systemd/system/phasezero-vibe-code-prepare.service
boot_target=/etc/systemd/system/phasezero-vibe-code.target
hook=/etc/systemd/system/sddm.service.d/50-phasezero-vibe-code.conf
sddm=/etc/sddm.conf.d/zz-phasezero-vibe-code.conf
autostart=/etc/xdg/autostart/phasezero-vibe-code-boot.desktop
runtime_login=/run/phasezero-vibe-code/login.conf
system_state=/var/lib/phasezero/vibe-code
marker='PhaseZero managed: Vibe Code'

packages=(python pyside6 jq git nodejs npm pnpm konsole dolphin kate sddm plasma-workspace
          plasma-desktop kwin xdg-utils xdg-desktop-portal-kde xorg-xwayland
          pipewire pipewire-pulse wireplumber grub)

error() { printf 'Vibe Code: %s\n' "$*" >&2; }

package_plan() {
    local package
    missing=()
    for package in "${packages[@]}"; do
        pacman -Qq "$package" >/dev/null 2>&1 || missing+=("$package")
    done
    [ -x /usr/bin/code ] || missing+=(code)
    if ! browser_package; then missing+=(firefox); fi
}

browser_package() {
    local browser
    for browser in firefox brave chromium google-chrome-stable microsoft-edge-stable falkon; do
        [ -x "/usr/bin/$browser" ] && pacman -Qoq "/usr/bin/$browser" >/dev/null 2>&1 && return 0
    done
    return 1
}

ensure_browser_default() {
    local selected entry
    selected="$(xdg-settings get default-web-browser 2>/dev/null || true)"
    if [[ "$selected" =~ ^[A-Za-z0-9._-]+\.desktop$ ]] &&
        { [ -f "/usr/share/applications/$selected" ] ||
          [ -f "${XDG_DATA_HOME:-$HOME/.local/share}/applications/$selected" ]; }; then
        return 0
    fi
    for entry in firefox.desktop brave-browser.desktop chromium.desktop google-chrome.desktop +        microsoft-edge.desktop org.kde.falkon.desktop; do
        if [ -f "/usr/share/applications/$entry" ] && xdg-settings set default-web-browser "$entry"; then
            return 0
        fi
    done
    error "não foi possível definir o navegador padrão desta sessão"
    return 1
}

install_packages() {
    local transaction package pending
    package_plan
    [ "${#missing[@]}" -ne 0 ] || return 0
    transaction="$(pacman -Sp --needed --noconfirm --print-format '%n' -- "${missing[@]}")" || {
        error "pacman não resolveu as dependências. Revise os repositórios da distribuição."; return 1;
    }
    [ -n "$transaction" ] || { error "pacotes ausentes sem transação resolvida"; return 1; }
    while IFS= read -r package; do
        if pacman -Qq "$package" >/dev/null 2>&1; then
            error "a instalação também alteraria $package. Atualize o sistema pelo fluxo da distribuição e repita."
            return 1
        fi
    done <<< "$transaction"
    # pnpm is a JS package whose installed Node is reused. Native additions
    # must use a synchronized system to avoid a partial Arch upgrade.
    if [ "$transaction" != pnpm ]; then
        pending="$(pacman -Qu)" || return 1
        [ -z "$pending" ] || { error "há atualizações pendentes. Atualize o sistema e repita."; return 1; }
    fi
    printf 'Instalando pacotes ausentes: %s\n' "${missing[*]}"
    pacman -S --needed --noconfirm -- "${missing[@]}"
}

verify_tools() {
    local command
    for command in /usr/bin/{python3,jq,git,node,npm,pnpm,code,konsole,dolphin,kate,startplasma-wayland,xdg-open,sddm}; do
        [ -x "$command" ] || { error "arquivo de ferramenta ausente: $command"; return 1; }
    done
    /usr/bin/python3 -c 'from PySide6.QtWidgets import QApplication'
    browser_package || { error "navegador nativo ausente"; return 1; }
    /usr/bin/node --version
    /usr/bin/pnpm --version
}

describe() {
    package_plan
    printf 'Perfil: Vibe Code (Plasma Wayland)\n'
    printf 'Pacotes a instalar: %s\n' "${missing[*]:-nenhum}"
    printf '%s\n' 'Boot: adiciona PhaseZero Vibe Code (Plasma) ao GRUB, com backup da configuração.'
    printf '%s\n' 'Login automático: uma tentativa ao escolher esta entrada. Sair volta ao seletor do SDDM.'
    printf '%s\n' 'Desbloqueio de disco/cofre e autenticação dos provedores seguem seus fluxos próprios.'
}

has_autologin_keys() {
    awk '
        /^[[:space:]]*\[/ { active=($0 ~ /^[[:space:]]*\[Autologin\][[:space:]]*$/) }
        active && /^[[:space:]]*(User|Session|Relogin)[[:space:]]*=/ { found=1 }
        END { exit !found }
    ' "$1"
}

preflight_boot() {
    local file active
    pz_boot_require_current_root_target
    pz_boot_preflight_grub
    command -v grub-script-check >/dev/null
    [ -x /etc/grub.d/10_linux ] && [ -f "$grub" ] && [ ! -L "$grub" ] ||
        { error "GRUB precisa ter 10_linux e grub.cfg locais"; return 1; }
    active="$(systemctl show -p Id --value display-manager.service 2>/dev/null || true)"
    if [ -n "$active" ] && [ "$active" != sddm.service ] && [ "$active" != display-manager.service ]; then
        error "SDDM precisa ser o gerenciador de login da máquina (atual: $active)."
        return 1
    fi
    for file in /etc/sddm.conf /etc/sddm.conf.d/*.conf; do
        [ -f "$file" ] && [ "$file" != "$sddm" ] || continue
        if { [ "$file" = /etc/sddm.conf ] || [[ "$file" > "$sddm" ]]; } && has_autologin_keys "$file"; then
            error "prioridade de autologin em $file. Resolva o conflito pelo gerenciador atual e repita."
            return 1
        fi
    done
}

check_owned() {
    local path
    for path in "$generator" "$root_config" "$session_helper" "$unit" "$boot_target" "$hook" "$autostart"; do
        if [ -L "$path" ] || { [ -e "$path" ] && ! grep -Fq "$marker" "$path"; }; then
            error "arquivo de outra origem preservado: $path"
            return 1
        fi
    done
    if { [ -e "$sddm" ] || [ -L "$sddm" ]; } && [ "$(readlink "$sddm" || true)" != "$runtime_login" ]; then
        error "arquivo de outra origem preservado: $sddm"
        return 1
    fi
}

grub_block() {
    local source="$1" mode="$2"
    awk -v begin="### BEGIN $generator ###" -v end="### END $generator ###" -v mode="$mode" '
        $0 == begin { if (inside || blocks++) exit 2; inside=1 }
        (mode == "extract") == inside { print }
        $0 == end { if (!inside) exit 2; inside=0 }
        END { if (inside || (mode == "extract" && blocks != 1)) exit 2 }
    ' "$source"
}

verify_grub() {
    local candidate="$1" expected="$2" count markers
    grub-script-check "$candidate"
    pz_boot_validate_grub_cfg_safe "$candidate"
    count="$(grep -Ec "^menuentry .* --id='$boot_id' " "$candidate" || true)"
    markers="$(grep -Ec '^[[:blank:]]*linux(efi|16)?[[:blank:]].*[[:blank:]]phasezero\.vibe=1[[:blank:]]+systemd\.unit=phasezero-vibe-code\.target([[:blank:]]|$)' "$candidate" || true)"
    [ "$count" -eq "$expected" ] && [ "$markers" -eq "$expected" ] ||
        { error "grub.cfg não contém exatamente a entrada e o marcador esperados"; return 1; }
}

write_boot_files() {
    pz_boot_atomic_install "$PZ_ROOT/linux/boot/vibe-code-grub.sh" "$generator" 0755
    pz_boot_atomic_install "$PZ_ROOT/linux/boot/vibe-code-session.sh" "$session_helper" 0755
    printf '# %s\n%s\n%s\n' "$marker" "$owner" "$launcher" > "$backup/config.new"
    pz_boot_atomic_install "$backup/config.new" "$root_config"
    cat > "$backup/unit.new" <<EOF
# $marker
[Unit]
Description=PhaseZero Vibe Code one-boot login
ConditionKernelCommandLine=phasezero.vibe=1
After=local-fs.target
Before=sddm.service

[Service]
Type=oneshot
ExecStart=$session_helper prepare
RuntimeDirectory=phasezero-vibe-code
RemainAfterExit=yes
TimeoutStartSec=5s
EOF
    pz_boot_atomic_install "$backup/unit.new" "$unit"
    cat > "$backup/target.new" <<EOF
# $marker
[Unit]
Description=PhaseZero Vibe Code (Plasma)
Requires=multi-user.target
Wants=sddm.service
After=multi-user.target sddm.service
AllowIsolate=yes
EOF
    pz_boot_atomic_install "$backup/target.new" "$boot_target"
    cat > "$backup/hook.new" <<EOF
# $marker
[Unit]
Wants=phasezero-vibe-code-prepare.service
After=phasezero-vibe-code-prepare.service
EOF
    pz_boot_atomic_install "$backup/hook.new" "$hook"
    cat > "$backup/autostart.new" <<EOF
# $marker
[Desktop Entry]
Type=Application
Name=Vibe Code
Exec=$session_helper launch
OnlyShowIn=KDE;
EOF
    pz_boot_atomic_install "$backup/autostart.new" "$autostart"
    if [ ! -L "$sddm" ]; then
        install -d "$(dirname "$sddm")"
        ln -s -- "$runtime_login" "$sddm"
    fi
    systemd-analyze verify "$unit" "$boot_target"
}

boot_transaction() (
    set -euo pipefail
    local wanted="$1" path index=0 rc
    local -a files=("$generator" "$root_config" "$session_helper" "$unit" "$boot_target" "$hook" "$autostart" "$sddm" "$grub")
    install -d -m 0755 "$system_state"
    exec 9>"$system_state/lock"
    flock -n 9 || { error "outra configuração Vibe Code em andamento"; return 1; }
    preflight_boot
    check_owned
    backup="$(mktemp -d "$system_state/backup.XXXXXX")"
    for path in "${files[@]}"; do
        if [ -e "$path" ] || [ -L "$path" ]; then cp -a -- "$path" "$backup/$index"; fi
        index=$((index + 1))
    done
    rollback() {
        rc=$?
        if [ "$rc" -ne 0 ]; then
            index=0
            for path in "${files[@]}"; do
                if [ -e "$backup/$index" ] || [ -L "$backup/$index" ]; then
                    if [ -L "$backup/$index" ]; then
                        ln -sfn -- "$(readlink "$backup/$index")" "$path"
                    else
                        pz_boot_atomic_install "$backup/$index" "$path" "$(stat -c %a "$backup/$index")"
                    fi
                else
                    rm -f -- "$path"
                fi
                index=$((index + 1))
            done
            systemctl daemon-reload || true
            error "configuração anterior restaurada. Evidência: $backup"
        fi
        exit "$rc"
    }
    trap rollback EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    grub_block "$grub" strip > "$backup/grub.candidate"
    if [ "$wanted" -eq 1 ]; then
        write_boot_files
        if ! grub-mkconfig -o "$backup/grub.generated" > "$backup/grub-mkconfig.log" 2>&1 ||
            pz_boot_grub_log_has_fatal_errors "$backup/grub-mkconfig.log"; then
            tail -20 "$backup/grub-mkconfig.log" >&2
            return 1
        fi
        grub_block "$backup/grub.generated" extract >> "$backup/grub.candidate"
    else
        rm -f -- "$generator" "$root_config" "$session_helper" "$unit" "$boot_target" "$hook" "$autostart" "$sddm"
    fi
    verify_grub "$backup/grub.candidate" "$wanted"
    cmp <(grub_block "$grub" strip) <(grub_block "$backup/grub.candidate" strip)
    pz_boot_atomic_install "$backup/grub.candidate" "$grub" "$(stat -c %a "$grub")"
    systemctl daemon-reload
    verify_grub "$grub" "$wanted"
    printf 'GRUB validado. Backup: %s\n' "$backup"
)

command -v pacman >/dev/null || { error "instalador suportado em Arch/Manjaro/BigLinux"; exit 69; }

case "$action" in
    plan|status)
        describe
        if [ -f "$root_config" ] && [ -f "$unit" ]; then
            printf '%s\n' 'Arquivos de boot registrados. Para validar grub.cfg, use verify.'
        fi
        ;;
    verify)
        if [ "$EUID" -ne 0 ]; then pz_admin_run /usr/bin/bash "$0" verify; exit $?; fi
        preflight_boot
        check_owned
        [ -x "$generator" ] && [ -x "$session_helper" ] && [ -f "$hook" ] &&
            [ -f "$root_config" ] && [ -f "$autostart" ] &&
            [ "$(readlink "$sddm")" = "$runtime_login" ]
        systemd-analyze verify "$unit" "$boot_target"
        verify_grub "$grub" 1
        verify_tools
        ;;
    remove)
        [ "${1:-}" = --yes ] || { error "use remove --yes para retirar a entrada GRUB"; exit 64; }
        if [ "$EUID" -ne 0 ]; then pz_admin_run /usr/bin/bash "$0" remove --yes; exit $?; fi
        boot_transaction 0
        ;;
    install)
        [ "$EUID" -ne 0 ] || { error "execute como usuário da sessão"; exit 77; }
        [ "${1:-}" = --yes ] || { describe; error "revise o plano e use install --yes"; exit 64; }
        owner="$(pz_target_user)"
        launcher="${XDG_BIN_HOME:-$HOME/.local/bin}/phasezero-control-center"
        if ! [ -x "$launcher" ] || ! "$launcher" --help 2>/dev/null | grep -Fq -- --vibe-code; then
            [ -f "$PZ_ROOT/packaging/linux/install-user.sh" ] ||
                { error "use o checkout do projeto para preparar o runtime de usuário"; exit 69; }
            pz_admin_run /usr/bin/bash "$0" _packages
            bash "$PZ_ROOT/packaging/linux/install-user.sh"
        else
            bash "$PZ_ROOT/linux/ai/agent-shortcuts.sh" "$launcher"
        fi
        "$launcher" --help | grep -F -- --vibe-code >/dev/null
        pz_admin_run /usr/bin/bash "$0" _install "$owner" "$launcher"
        ensure_browser_default
        printf '%s\n' 'No próximo boot, selecione PhaseZero Vibe Code (Plasma). BigLinux continua no menu.'
        ;;
    _packages)
        [ "$EUID" -eq 0 ] || exit 77
        install_packages
        ;;
    _install)
        [ "$EUID" -eq 0 ] || exit 77
        owner="${1:?}"
        launcher="${2:?}"
        [[ "$owner" =~ ^[[:alnum:]_][[:alnum:]_.-]*$ ]] && [ "$owner" != root ] || exit 64
        [[ "$launcher" = /* && ! "$launcher" =~ [[:cntrl:]] ]] || exit 64
        runuser -u "$owner" -- test -x "$launcher"
        preflight_boot
        install_packages
        verify_tools
        boot_transaction 1
        ;;
    *)
        error "uso: pz boot vibe-code (plan|status|install --yes|verify|remove --yes)"
        exit 64
        ;;
esac
