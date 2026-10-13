#!/usr/bin/env bash
# tune-common.sh - contrato apply/revert/status compartilhado pelas áreas de tuning.
#
# Por que existe: as áreas de tuning eram apply-only. A UI não conseguia mostrar
# estado real nem desligar uma otimização, então qualquer switch seria mentira.
# Aqui cada mutação é declarada enquanto acontece e gravada em um estado por
# área, de modo que `status` responda com evidência e `revert` desfaça com o
# backup/valor anterior que foi realmente capturado.
#
# Estado: $PZ_STATE/tuning/<area>.json
#   { schema, area, appliedAt, dryRun:false, entries:[ ... ] }
#
# Tipos de entrada:
#   file    { path, scope, created, backup, sha256 }
#   setting { tool, key, value, previous, had }
#   service { name, wasEnabled }
#
# Uso mínimo em um script de área:
#
#   source "$PZ_ROOT/linux/tuning/tune-common.sh"
#   pz_tune_init gaming "$@"
#   pz_tune_apply() { pz_tune_file /etc/gamemode.ini root <<'EOF' ... EOF }
#   pz_tune_main

source "$PZ_ROOT/linux/lib/json-envelope.sh"

PZ_TUNE_AREA=""
PZ_TUNE_ACTION="apply"
PZ_TUNE_ENTRIES='[]'
PZ_TUNE_REVERT_SUMMARY=""
PZ_TUNE_SCHEMA=1

pz_tune_require_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    pz_error "jq é obrigatório para o contrato de tuning (apply/revert/status)"
    return 1
}

pz_tune_state_file() {
    printf '%s/tuning/%s.json\n' "$PZ_STATE" "${1:-$PZ_TUNE_AREA}"
}

# pz_tune_init <area> [apply|revert|status] [--dry-run]
#
# Aceita também a forma legada `<script> --dry-run`, que significa
# `apply --dry-run`, para não quebrar chamadas existentes.
pz_tune_init() {
    PZ_TUNE_AREA="${1:-}"
    [ -n "$PZ_TUNE_AREA" ] || { pz_error "pz_tune_init exige o nome da área"; return 1; }
    shift
    PZ_MODULE="tune-$PZ_TUNE_AREA"
    PZ_TUNE_ACTION="apply"

    local arg
    for arg in "$@"; do
        case "$arg" in
            apply|revert|status) PZ_TUNE_ACTION="$arg" ;;
            --dry-run) PZ_DRY_RUN=1 ;;
            "") ;;
            *)
                pz_error "uso: ${0##*/} [apply|revert|status] [--dry-run]"
                return 1
                ;;
        esac
    done
    export PZ_DRY_RUN="${PZ_DRY_RUN:-0}"
    pz_tune_require_jq
}

pz_tune_dry_run() { [ "${PZ_DRY_RUN:-0}" = "1" ]; }

pz_tune_append_entry() {
    PZ_TUNE_ENTRIES="$(jq --argjson entry "$1" '. + [$entry]' <<< "$PZ_TUNE_ENTRIES")"
}

# --- mutações declaradas ---------------------------------------------------

# pz_tune_file <path> <scope>   (conteúdo via stdin)
#
# Envolve pz_write_managed_file para que o backup e o ledger continuem sendo
# os mesmos do resto do projeto, e registra o suficiente para reverter:
# se o arquivo é nosso (created) some no revert; se já existia, volta do backup.
pz_tune_file() {
    local path="${1:-}" scope="${2:-user}" content sum existed=0 backup="" rc=0
    [ -n "$path" ] || { pz_error "pz_tune_file exige um caminho"; return 1; }
    # O `x` sentinela preserva a newline final do heredoc: sem ele a captura
    # `$(cat)` a descarta e o sha registrado nunca bateria com o do disco.
    content="$(cat; printf 'x')"
    content="${content%x}"
    sum="$(printf '%s' "$content" | sha256sum | awk '{print $1}')"

    if pz_tune_dry_run; then
        pz_info "dry-run: escreveria arquivo gerenciado ($scope): $path"
        return 0
    fi

    [ -f "$path" ] && existed=1
    # Backup ANTES da escrita: pz_backup_latest depois da escrita devolvia o
    # backup que a própria escrita acabou de criar (conteúdo já PhaseZero de
    # um apply anterior), e o revert restaurava o intermediário, não o
    # original do usuário.
    pre_backup=""
    if [ "$existed" = "1" ]; then
        pre_backup="$(pz_backup_latest "$path" 2>/dev/null || true)"
    fi
    printf '%s' "$content" | pz_write_managed_file "$path" "$scope" || rc=$?
    if [ "$rc" -eq 77 ]; then
        # Sem admin bridge: nada foi escrito, então nada pode ser registrado
        # como reversível. Silenciar aqui produziria um status mentiroso.
        pz_warn "sem privilégio para escrever $path; entrada não registrada"
        return 0
    fi
    [ "$rc" -eq 0 ] || return "$rc"

    # Evidência antes de registro: a escalada de privilégio pode falhar sem
    # propagar erro. Registrar aqui às cegas produziria um `status` que jura
    # ter aplicado algo que não existe no disco, e um `revert` que tentaria
    # desfazer o que nunca foi feito.
    if [ ! -e "$path" ] || [ "$(sha256sum -- "$path" 2>/dev/null | awk '{print $1}')" != "$sum" ]; then
        pz_warn "escrita não confirmada em $path; entrada não registrada"
        return 0
    fi

    backup="$pre_backup"
    if [ "$existed" = "1" ] && [ -z "$backup" ]; then
        # Primeira escrita gerenciada: o backup criado pela própria escrita
        # guarda o conteúdo original do usuário.
        backup="$(pz_backup_latest "$path" 2>/dev/null || true)"
    fi
    pz_tune_append_entry "$(jq -n \
        --arg path "$path" --arg scope "$scope" --arg backup "$backup" --arg sha "$sum" \
        --argjson created "$([ "$existed" = "1" ] && echo false || echo true)" \
        '{kind: "file", path: $path, scope: $scope, created: $created, backup: $backup, sha256: $sha}')"
}

# pz_tune_setting <tool> <key> <value>
#
# Configuração global de ferramenta (git/npm). O valor anterior é capturado
# ANTES da escrita: é a única forma de o revert devolver o que o usuário tinha
# em vez de apagar a preferência dele.
pz_tune_setting() {
    local tool="${1:-}" key="${2:-}" value="${3:-}" previous="" had=false
    # `A && B || C` não é if-then-else: com tool preenchido e key vazia, o C
    # roda de qualquer forma — aqui até calharia de estar certo, mas a forma
    # explícita não depende disso.
    if [ -z "$tool" ] || [ -z "$key" ]; then
        pz_error "pz_tune_setting exige tool e key"
        return 1
    fi
    command -v "$tool" >/dev/null 2>&1 || { pz_warn "$tool ausente; ajuste '$key' ignorado"; return 0; }

    # `npm config get` inicializa cache e .npmrc no HOME: consultar durante um
    # preview escreveria no host, o que contradiz dry-run. Só ferramentas de
    # leitura inerte são sondadas nesse modo.
    if pz_tune_dry_run && [ "$tool" = "npm" ]; then
        pz_info "dry-run: npm config $key = $value (atual: <não consultado>)"
        return 0
    fi

    if previous="$(pz_tune_setting_get "$tool" "$key")"; then
        had=true
    else
        previous=""
    fi

    if pz_tune_dry_run; then
        pz_info "dry-run: $tool config $key = $value (atual: ${previous:-<não definido>})"
        return 0
    fi

    pz_tune_setting_set "$tool" "$key" "$value" || { pz_warn "falha ao ajustar $tool $key"; return 0; }
    pz_tune_append_entry "$(jq -n \
        --arg tool "$tool" --arg key "$key" --arg value "$value" --arg previous "$previous" \
        --argjson had "$had" \
        '{kind: "setting", tool: $tool, key: $key, value: $value, previous: $previous, had: $had}')"
}

pz_tune_setting_get() {
    local tool="$1" key="$2" value
    case "$tool" in
        git) value="$(git config --global --get "$key" 2>/dev/null || true)" ;;
        npm) value="$(npm config get "$key" 2>/dev/null || true)"
             [ "$value" = "undefined" ] || [ "$value" = "null" ] && value="" ;;
        *)   return 1 ;;
    esac
    [ -n "$value" ] || return 1
    printf '%s' "$value"
}

pz_tune_setting_set() {
    local tool="$1" key="$2" value="$3"
    case "$tool" in
        git) git config --global "$key" "$value" ;;
        npm) npm config set "$key" "$value" >/dev/null ;;
        *)   return 1 ;;
    esac
}

pz_tune_setting_unset() {
    local tool="$1" key="$2"
    case "$tool" in
        git) git config --global --unset-all "$key" 2>/dev/null || true ;;
        npm) npm config delete "$key" >/dev/null 2>&1 || true ;;
    esac
}

# pz_tune_service <name> — habilita o serviço e lembra se ele já estava ligado,
# para o revert não desligar algo que o usuário mantinha por conta própria.
pz_tune_service() {
    local name="${1:-}" was=false
    [ -n "$name" ] || return 1
    command -v systemctl >/dev/null 2>&1 || { pz_warn "systemctl ausente; serviço '$name' ignorado"; return 0; }
    systemctl is-enabled "$name" >/dev/null 2>&1 && was=true

    if pz_tune_dry_run; then
        pz_info "dry-run: habilitaria o serviço '$name' (já habilitado: $was)"
        return 0
    fi
    if [ "$was" = "true" ]; then
        pz_info "serviço já habilitado: $name"
        return 0
    fi
    if ! pz_admin_run systemctl enable --now "$name" >/dev/null 2>&1; then
        pz_warn "sem privilégio para habilitar '$name'; entrada não registrada"
        return 0
    fi
    pz_tune_append_entry "$(jq -n --arg name "$name" --argjson wasEnabled false \
        '{kind: "service", name: $name, wasEnabled: $wasEnabled}')"
}

# --- estado ----------------------------------------------------------------

pz_tune_state_save() {
    local file entries
    file="$(pz_tune_state_file)"
    entries="$PZ_TUNE_ENTRIES"
    if [ "$(jq 'length' <<< "$entries")" = "0" ]; then
        pz_warn "nenhuma mutação registrada em '$PZ_TUNE_AREA'; estado não gravado"
        return 0
    fi
    pz_state_init
    mkdir -p "$(dirname "$file")"
    jq -n --argjson schema "$PZ_TUNE_SCHEMA" --arg area "$PZ_TUNE_AREA" \
        --arg appliedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson entries "$entries" \
        '{schema: $schema, area: $area, appliedAt: $appliedAt, entries: $entries}' > "$file"
    chmod 0600 "$file" 2>/dev/null || true
}

pz_tune_state_load() {
    local file
    file="$(pz_tune_state_file "${1:-$PZ_TUNE_AREA}")"
    [ -f "$file" ] || return 1
    cat "$file"
}

# --- status ----------------------------------------------------------------
#
# `applied` só é verdadeiro quando existe estado E todos os arquivos declarados
# continuam presentes. Arquivo sumido ou alterado por fora vira `drift`, não
# vira silêncio: a UI precisa distinguir "desligado" de "mexeram nisso".
pz_tune_status_json() {
    local area="${1:-$PZ_TUNE_AREA}" state="" file_items='[]' drift=false applied=true
    if ! state="$(pz_tune_state_load "$area")"; then
        jq -n --arg area "$area" --argjson schema "$PZ_TUNE_SCHEMA" \
            '{schema: $schema, area: $area, applied: false, drift: false, appliedAt: "", entries: [], files: []}'
        return 0
    fi

    local path scope sha present managed entry
    while IFS=$'\037' read -r path scope sha; do
        [ -n "$path" ] || continue
        present=false
        managed=false
        if [ -e "$path" ]; then
            present=true
            if [ -r "$path" ] && [ "$(sha256sum -- "$path" 2>/dev/null | awk '{print $1}')" = "$sha" ]; then
                managed=true
            fi
        fi
        # Arquivo ausente derruba `applied`; arquivo presente porém editado por
        # fora continua aplicado, mas sinaliza drift.
        [ "$present" = "true" ] || { drift=true; applied=false; }
        [ "$managed" = "true" ] || drift=true
        entry="$(jq -n --arg path "$path" --arg scope "$scope" \
            --argjson present "$present" --argjson managed "$managed" \
            '{path: $path, scope: $scope, present: $present, managed: $managed}')"
        file_items="$(jq --argjson entry "$entry" '. + [$entry]' <<< "$file_items")"
    done < <(jq -r '.entries[] | select(.kind == "file") | [.path, .scope, .sha256] | join("\u001f")' <<< "$state")

    # Uma área cujas entradas são só settings/serviços continua aplicada: não há
    # arquivo para conferir, e o estado gravado é a evidência.
    jq -n --argjson schema "$PZ_TUNE_SCHEMA" --arg area "$area" \
        --argjson applied "$applied" --argjson drift "$drift" \
        --arg appliedAt "$(jq -r '.appliedAt // ""' <<< "$state")" \
        --argjson entries "$(jq '.entries' <<< "$state")" \
        --argjson files "$file_items" \
        '{schema: $schema, area: $area, applied: $applied, drift: $drift, appliedAt: $appliedAt, entries: $entries, files: $files}'
}

# --- revert ----------------------------------------------------------------

pz_tune_revert_run() {
    local state reverted=0
    PZ_TUNE_REVERT_SUMMARY=""
    if ! state="$(pz_tune_state_load)"; then
        pz_info "nada aplicado em '$PZ_TUNE_AREA'; revert é no-op"
        PZ_TUNE_REVERT_SUMMARY="tuning '$PZ_TUNE_AREA' já estava desligado"
        return 0
    fi

    local kind path scope created backup tool key previous had name
    # Ordem inversa da aplicação: dependências (serviço depois do arquivo de
    # regras, por exemplo) desfazem na ordem certa.
    # Separador é US (0x1f), não tab: tab é whitespace para `read`, que então
    # colapsa campos vazios consecutivos e desloca tudo à direita — foi assim
    # que `setting` chegou aqui com tool="true" e key vazia.
    while IFS=$'\037' read -r kind path scope created backup tool key previous had name; do
        case "$kind" in
            file)
                if pz_tune_dry_run; then
                    pz_info "dry-run: reverteria $path (criado: $created)"
                elif [ "$created" = "true" ]; then
                    pz_tune_remove_path "$path" "$scope"
                elif [ -n "$backup" ] && [ -f "$backup" ]; then
                    pz_restore_file "$path" "$scope" >/dev/null || pz_warn "falha ao restaurar $path"
                else
                    pz_warn "sem backup para $path; arquivo mantido como está"
                fi
                ;;
            setting)
                if pz_tune_dry_run; then
                    pz_info "dry-run: devolveria $tool $key para ${previous:-<não definido>}"
                elif [ "$had" = "true" ]; then
                    pz_tune_setting_set "$tool" "$key" "$previous" || pz_warn "falha ao devolver $tool $key"
                else
                    pz_tune_setting_unset "$tool" "$key"
                fi
                ;;
            service)
                if pz_tune_dry_run; then
                    pz_info "dry-run: desabilitaria o serviço '$name'"
                else
                    pz_admin_run systemctl disable --now "$name" >/dev/null 2>&1 \
                        || pz_warn "falha ao desabilitar '$name'"
                fi
                ;;
            *) continue ;;
        esac
        reverted=$((reverted + 1))
    done < <(jq -r '[.entries[]] | reverse | .[] | [
            .kind, (.path // ""), (.scope // ""), ((.created // false) | tostring),
            (.backup // ""), (.tool // ""), (.key // ""), (.previous // ""),
            ((.had // false) | tostring), (.name // "")
        ] | join("\u001f")' <<< "$state")

    if declare -F pz_tune_after_revert >/dev/null; then
        pz_tune_after_revert
    fi

    if pz_tune_dry_run; then
        PZ_TUNE_REVERT_SUMMARY="revert de '$PZ_TUNE_AREA' planejado: $reverted mutação(ões)"
    else
        rm -f -- "$(pz_tune_state_file)"
        ledger_record --module "$PZ_MODULE" --action tune-revert --scope user --reversible false
        PZ_TUNE_REVERT_SUMMARY="tuning '$PZ_TUNE_AREA' revertido: $reverted mutação(ões)"
    fi
}

pz_tune_remove_path() {
    local path="$1" scope="${2:-user}"
    [ -e "$path" ] || return 0
    if [ "$scope" = "root" ] && [ "$EUID" -ne 0 ]; then
        pz_admin_run rm -f -- "$path" || pz_warn "falha ao remover $path"
    else
        rm -f -- "$path" || pz_warn "falha ao remover $path"
    fi
    pz_info "removido $path"
}

# --- despacho --------------------------------------------------------------
#
# O script de área define pz_tune_apply (obrigatório) e, se precisar,
# pz_tune_after_revert (ex.: recarregar sysctl depois de remover o arquivo).
pz_tune_main() {
    pz_result_guard_install "$PZ_MODULE"
    # stdout é do contrato JSON e de mais nada. pz_info escreve em stdout, então
    # o corpo roda com stdout redirecionado para stderr (vira log na UI) e o
    # envelope sai pelo fd 3, que aponta para o stdout real.
    exec 3>&1
    case "$PZ_TUNE_ACTION" in
        status)
            # Área explícita: a função aceita argumento, e chamá-la sem ele faz
            # o shellcheck (com razão) perguntar se o $1 do script deveria
            # entrar aqui.
            pz_tune_status_json "$PZ_TUNE_AREA" >&3
            ;;
        revert)
            pz_tune_revert_run 1>&2
            pz_result_envelope ok "$PZ_TUNE_REVERT_SUMMARY" >&3
            ;;
        apply)
            declare -F pz_tune_apply >/dev/null || { pz_error "área '$PZ_TUNE_AREA' não define pz_tune_apply"; return 1; }
            pz_tune_apply 1>&2
            if pz_tune_dry_run; then
                pz_result_envelope ok "tuning '$PZ_TUNE_AREA' planejado (dry-run)" >&3
            else
                pz_tune_state_save 1>&2
                pz_result_envelope ok "tuning '$PZ_TUNE_AREA' aplicado" >&3
            fi
            ;;
        *)
            pz_error "ação de tuning inválida: $PZ_TUNE_ACTION"
            return 1
            ;;
    esac
    pz_result_emitted
}
