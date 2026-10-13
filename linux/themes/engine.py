"""Motor transacional de temas.

Fluxo obrigatório por operação:
1. Ler estado efetivo.
2. Gerar plano (com snapshot do estado atual).
3. Confirmar dependências/riscos (token + blockers).
4. Aplicar.
5. Verificar novamente.
6. Atualizar chave.
7. Em falha/cancelamento, restaurar visual e configuração anterior.

Idempotência: apply/verify/rollback repetidos devolvem o mesmo resultado sem
reaplicar.
"""

from __future__ import annotations

import os
import shutil
import time
from pathlib import Path

from . import SCHEMA, STATES
from .catalog import (
    FEATURES,
    KDE_EXTENSIONS,
    PROFILES,
    QUICK_ENVIRONMENTS,
    STEAM_PLUGINS,
    feature_by_id,
    load_wallpapers,
    profile_by_id,
    wallpaper_by_id,
)
from .kde import ConfigWrite, KdeSession, KdeStateError, count_plasma_crashes, process_running
from .models import FeatureSpec, ProfileSpec
from .platform import HostFacts, detect
from . import state

PLAN_TTL_SECONDS = state.PLAN_TTL_SECONDS
PREVIEW_TTL_SECONDS = state.PREVIEW_TTL_SECONDS
BATTERY_PAUSE_PERCENT = 40


class ThemesError(RuntimeError):
    """Erro esperado e acionável do motor de temas."""


def adapter_for(_spec: FeatureSpec):
    """Registro de adapters; implementações reais chegam com a camada de
    aparência/acessibilidade. Sem adapter, o estado é `indisponivel` com
    motivo — nunca sucesso aparente."""
    from . import features as _features  # import tardio para evitar ciclo

    return _features.adapter_for(_spec)


def _params_match(current_params: dict | None, wanted_params: dict | None) -> bool:
    """Todos os params explicitamente pedidos precisam bater com o estado atual."""
    for key, value in (wanted_params or {}).items():
        if str((current_params or {}).get(key, "")) != str(value):
            return False
    return True


# --------------------------------------------------------------------------
# Leitura de estado efetivo
# --------------------------------------------------------------------------

def feature_state(spec: FeatureSpec, facts: HostFacts, session: KdeSession) -> dict:
    compatible, reason = facts.plasma_compatible(spec.plasma_major)
    if not compatible:
        return {"state": "indisponivel", "reason": reason}
    adapter = adapter_for(spec)
    if adapter is None:
        return {"state": "indisponivel", "reason": "adapter ainda não integrado"}
    try:
        return adapter.effective(facts, session)
    except KdeStateError as exc:
        return {"state": "degradado", "reason": str(exc)}
    except Exception as exc:  # noqa: BLE001 - estado ilegível vira degradado, nunca exceção crua
        return {"state": "degradado", "reason": f"leitura falhou: {exc}"}


def _wallpaper_hero(session: KdeSession, compatible: bool) -> dict:
    if not compatible:
        return {"state": "indisponivel", "reason": "sessão Plasma 6 não detectada"}
    try:
        screens = session.read_wallpapers()
    except KdeStateError as exc:
        return {"state": "degradado", "reason": str(exc)}
    return {
        "state": "ligado",
        "screens": [
            {
                "screen": item.get("screen"),
                "plugin": item.get("wallpaperPlugin"),
                "mode": item.get("wallpaperMode"),
            }
            for item in screens
        ],
    }


def _profile_effective(facts: HostFacts, session: KdeSession) -> dict:
    states = {
        feature_id: feature_state(spec, facts, session)
        for feature_id, spec in FEATURES.items()
    }
    active_features = {
        feature_id for feature_id, value in states.items()
        if value.get("state") in ("ligado", "aplicando", "pausado-bateria", "pausado-jogo")
    }
    for profile in PROFILES.values():
        targets = set(profile.features)
        if not targets:
            continue
        if not targets.intersection(active_features):
            continue
        matched = True
        for feature_id, target in profile.features.items():
            current = states.get(feature_id, {}).get("state")
            expected = "ligado" if target.get("state") == "ligado" else "desligado"
            if current != expected:
                matched = False
                break
        outside = active_features - targets
        if matched and not outside:
            return {"id": profile.id, "title": profile.title, "custom": False}
    return {"id": None, "title": "Personalizado", "custom": True}


def status_payload(facts: HostFacts | None = None, session: KdeSession | None = None) -> dict:
    facts = facts or detect()
    session = session or KdeSession(facts)
    compatible, reason = facts.plasma_compatible(6)
    _expire_due_previews()
    profile = _profile_effective(facts, session)
    return {
        "schema": SCHEMA,
        "ok": True,
        "host": facts.to_dict(),
        "plasma": {
            "compatible": compatible,
            "major": facts.plasma_major,
            "kwin": facts.kwin,
            "session": facts.session,
            "steamOs": facts.steam_os,
            "steamDeck": facts.steam_deck,
            "gameMode": facts.game_mode,
            "reason": reason if not compatible else "",
        },
        "profile": profile,
        "hero": {
            "themePhasezero": session.read_key("phasezero/theme.conf", "interface", "theme") or "sistema",
            "themeKde": session.read_key("plasmarc", "Theme", "name") or "",
            "colorscheme": session.read_key("kdeglobals", "General", "ColorScheme") or "",
            "wallpaper": _wallpaper_hero(session, compatible),
            "battery": {
                "onBattery": facts.on_battery,
                "percent": facts.battery_percent,
                "pausedBelow": BATTERY_PAUSE_PERCENT if facts.on_battery else None,
            },
            "decky": facts.decky,
            "gameMode": facts.game_mode,
        },
        "features": {
            feature_id: feature_state(spec, facts, session)
            for feature_id, spec in FEATURES.items()
        },
        "states": list(STATES),
    }


def catalog_payload(facts: HostFacts | None = None, session: KdeSession | None = None) -> dict:
    facts = facts or detect()
    session = session or KdeSession(facts)
    wallpapers = load_wallpapers()
    return {
        "schema": SCHEMA,
        "host": facts.to_dict(),
        "features": [
            {
                "id": spec.id,
                "title": spec.title,
                "description": spec.description,
                "section": spec.section,
                "kind": spec.kind,
                "invasive": spec.invasive,
                "risk": spec.risk,
                "params": list(spec.params),
                "requires": list(spec.requires),
                "state": feature_state(spec, facts, session),
            }
            for spec in FEATURES.values()
        ],
        "profiles": [
            {
                "id": profile.id,
                "title": profile.title,
                "description": profile.description,
                "audience": profile.audience,
                "features": profile.features,
            }
            for profile in PROFILES.values()
        ],
        "quickEnvironments": [
            {"id": env_id, **payload}
            for env_id, payload in QUICK_ENVIRONMENTS.items()
        ],
        "wallpapers": [
            {
                "id": item.id,
                "title": item.title,
                "kind": item.kind,
                "file": item.file,
                "sha256": item.sha256,
                "license": item.license,
                "color": item.color,
                "network": item.network,
                "available": _wallpaper_available(item, facts),
            }
            for item in wallpapers
        ],
        "kdeExtensions": [
            {
                "id": item.id,
                "storeId": item.store_id,
                "title": item.title,
                "plasmaMajor": item.plasma_major,
                "status": item.status,
                "reason": item.reason,
                "substitute": item.substitute,
                "license": item.license,
                "risk": item.risk,
            }
            for item in KDE_EXTENSIONS
        ],
        "steamPlugins": [
            {
                "id": item.id,
                "title": item.title,
                "deckyPlugin": item.decky_plugin,
                "license": item.license,
                "sourceUrl": item.source_url,
                "pinnedVersion": item.pinned_version,
                "verified": item.verified,
                "risk": item.risk,
            }
            for item in STEAM_PLUGINS
        ],
    }


def _wallpaper_available(item, facts: HostFacts) -> tuple[bool, str]:
    if item.source == "bundled":
        if item.kind == "solid":
            return True, ""
        path = Path(__file__).resolve().parents[2] / "assets" / "themes" / "wallpapers" / item.file
        if not path.exists():
            return False, "arquivo ausente do pacote"
        if item.sha256 and _sha256(path) != item.sha256:
            return False, "checksum diverge do manifest"
        return True, ""
    if item.network:
        return False, "requer rede (opt-in com aviso)"
    return False, "fonte não suportada nesta entrega"


def _sha256(path: Path) -> str:
    import hashlib

    digest = hashlib.sha256()
    try:
        digest.update(path.read_bytes())
    except OSError:
        return ""
    return digest.hexdigest()


# --------------------------------------------------------------------------
# Plano
# --------------------------------------------------------------------------

def _resolve_targets(
    *,
    profile: str = "",
    feature: str = "",
    feature_state_target: str = "",
    wallpaper: str = "",
    screen: str = "",
    wallpaper_target: str = "desktop",
    feature_params: dict | None = None,
) -> tuple[list[dict], list[str]]:
    actions: list[dict] = []
    blockers: list[str] = []

    if profile:
        spec = profile_by_id(profile)
        if spec is None:
            raise ThemesError(f"perfil desconhecido: {profile}")
        if profile == "essencial" and "video.smart-wallpaper" in (spec.features or {}):
            blockers.append("vídeo de fundo não é ativado no perfil Essencial")
        for feature_id, target in spec.features.items():
            actions.append({
                "kind": "feature",
                "featureId": feature_id,
                "target": target,
                "params": dict(target.get("params", {})),
            })

    if feature:
        spec = feature_by_id(feature)
        if spec is None:
            raise ThemesError(f"feature desconhecida: {feature}")
        if feature_state_target not in ("on", "off"):
            raise ThemesError("--state deve ser on ou off")
        supplied = dict(feature_params or {})
        unknown = sorted(set(supplied) - set(spec.params or ()))
        if unknown:
            raise ThemesError(
                f"parâmetro desconhecido para {feature}: {', '.join(unknown)}; "
                f"aceitos: {', '.join(spec.params or ()) or 'nenhum'}"
            )
        actions.append({
            "kind": "feature",
            "featureId": feature,
            "target": {"state": "ligado" if feature_state_target == "on" else "desligado"},
            "params": supplied,
        })

    if wallpaper:
        item = wallpaper_by_id(wallpaper)
        if item is None and not Path(wallpaper).expanduser().exists():
            raise ThemesError(f"wallpaper desconhecido: {wallpaper}")
        if wallpaper_target not in ("desktop", "lock"):
            raise ThemesError("--target deve ser desktop ou lock")
        if not screen:
            raise ThemesError("--screen é obrigatório para wallpaper")
        actions.append({
            "kind": "wallpaper",
            "wallpaperId": wallpaper,
            "screen": screen,
            "target": wallpaper_target,
            "params": {},
        })

    if not actions:
        raise ThemesError("selecione --profile, --feature ou --wallpaper")
    return actions, blockers


def create_plan(
    *,
    profile: str = "",
    feature: str = "",
    feature_state_target: str = "",
    wallpaper: str = "",
    screen: str = "",
    wallpaper_target: str = "desktop",
    # Several features are useless without input - an accent colour, a cursor
    # name, the Steam library a wallpaper lives in - and had no way to receive
    # it, so their adapters could only ever run on defaults or refuse.
    feature_params: dict | None = None,
    facts: HostFacts | None = None,
    session: KdeSession | None = None,
) -> dict:
    facts = facts or detect()
    session = session or KdeSession(facts)
    compatible, platform_reason = facts.plasma_compatible(6)
    # O snapshot do plano precisa capturar o estado já revertido de previews
    # vencidos, senão o rollback do plano consolida o preview expirado.
    _expire_due_previews()
    requested, blockers = _resolve_targets(
        profile=profile,
        feature=feature,
        feature_state_target=feature_state_target,
        wallpaper=wallpaper,
        screen=screen,
        wallpaper_target=wallpaper_target,
        feature_params=feature_params,
    )
    if not compatible:
        blockers.append(platform_reason)

    plan_actions: list[dict] = []
    for action in requested:
        entry = dict(action)
        if action["kind"] == "feature":
            spec = feature_by_id(action["featureId"])
            entry["title"] = spec.title if spec else action["featureId"]
            entry["configKeys"] = list(spec.config_keys) if spec else []
            if spec and spec.requires:
                for dependency in spec.requires:
                    dep_spec = feature_by_id(dependency)
                    if dep_spec is None:
                        blockers.append(f"{spec.title}: dependência desconhecida {dependency}")
            if spec and spec.invasive and action["target"].get("state") == "ligado":
                entry["risk"] = spec.risk
                entry["invasive"] = True
            current = feature_state(spec, facts, session) if spec else {"state": "indisponivel"}
            wanted = "ligado" if action["target"].get("state") == "ligado" else "desligado"
            # Unavailable means a prerequisite is missing and applying cannot
            # work, so it blocks. Degraded means the feature is half-applied or
            # inconsistent, and re-applying is exactly the repair - blocking it
            # left the product unable to fix the state a user is most likely to
            # be stuck in, with the honest report of the problem being what
            # prevented the fix.
            if current.get("state") == "indisponivel" and wanted == "ligado":
                blockers.append(f"{spec.title}: {current.get('reason', 'estado ilegível')}")
            elif current.get("state") == "degradado" and wanted == "ligado":
                entry["repairs"] = current.get("reason", "")
            entry["current"] = current
            # A noop must also require the requested params to match. The
            # state alone is binary while adapters carry modes (system/dark/
            # light): comparing only the state turned every mode switch into
            # a no-op plan whose apply did nothing.
            entry["noop"] = current.get("state") == wanted and _params_match(
                current.get("params"), action.get("params")
            )
            entry["risk"] = spec.risk if spec else "normal"
        elif action["kind"] == "wallpaper":
            if not compatible:
                blockers.append("wallpaper exige Plasma 6 com KWin")
                entry["noop"] = False
                plan_actions.append(entry)
                continue
            item = wallpaper_by_id(action["wallpaperId"])
            if item is None:
                path = Path(action["wallpaperId"]).expanduser()
                if not path.is_file():
                    blockers.append(f"arquivo de wallpaper não encontrado: {path}")
                entry["noop"] = False
                entry["risk"] = "normal"
                plan_actions.append(entry)
                continue
            available, reason = _wallpaper_available(item, facts)
            if not available:
                blockers.append(f"{item.title}: {reason}")
            entry["noop"] = False
            entry["risk"] = "normal"
        plan_actions.append(entry)

    # snapshot antes de qualquer alteração - plano bloqueado nunca executa,
    # e criar snapshot dele só churnava o pool de retenção que previews e
    # operações referenciam.
    snapshot_id = _create_snapshot(facts, session, plan_actions) if plan_actions and not blockers else ""
    plan_id = state.new_id("plan")
    confirmation = state.token()
    risk = "high" if any(action.get("risk") == "high" for action in plan_actions) else (
        "elevated" if any(action.get("risk") == "elevated" for action in plan_actions) else "normal"
    )
    record = {
        "schema": SCHEMA,
        "kind": "plan",
        "id": plan_id,
        "createdAt": int(time.time()),
        "host": facts.to_dict(),
        "profile": profile,
        "actions": plan_actions,
        "blockers": blockers,
        "ok": not blockers,
        "status": "blocked" if blockers else "ready",
        "risk": risk,
        "snapshotId": snapshot_id,
        "confirmToken": confirmation,
        "ttlSeconds": PLAN_TTL_SECONDS,
    }
    state.save("plans", plan_id, record)
    return record


def _create_snapshot(facts: HostFacts, session: KdeSession, actions: list[dict]) -> str:
    writer = ConfigWrite()
    for action in actions:
        if action["kind"] == "feature":
            for key in action.get("configKeys", ()):
                if ":" in key:
                    config, _, _rest = key.partition(":")
                    writer.track(session.config_path(config))
        elif action["kind"] == "wallpaper" and action.get("target") == "lock":
            writer.track(session.config_path("kscreenlockerrc"))
    record = {
        "schema": SCHEMA,
        "kind": "snapshot",
        "id": state.new_id("snapshot"),
        "createdAt": int(time.time()),
        "files": [],
        "wallpapers": [],
        "lockScreen": {"image": ""},
    }
    try:
        record["files"] = writer.capture()["files"]
    except Exception as exc:  # noqa: BLE001
        raise ThemesError(f"não foi possível capturar snapshot: {exc}") from exc
    if any(action["kind"] == "wallpaper" and action.get("target") == "desktop" for action in actions):
        try:
            screens = session.read_wallpapers()
        except KdeStateError as exc:
            raise ThemesError(f"snapshot de wallpapers impossível: {exc}") from exc
        record["wallpapers"] = [
            {
                "screen": item.get("screen"),
                "desktopIndex": item.get("desktopIndex"),
                "plugin": item.get("wallpaperPlugin"),
                "mode": item.get("wallpaperMode"),
                "config": item.get("config", {}),
            }
            for item in screens
        ]
    record["lockScreen"] = {"image": session.read_lock_screen_image()}
    state.save("snapshots", record["id"], record)
    return record["id"]


# --------------------------------------------------------------------------
# Preview (somente wallpaper; 15 segundos; expiração causa rollback)
# --------------------------------------------------------------------------

def preview_plan(
    plan_id: str,
    *,
    confirmation: str = "",
    facts: HostFacts | None = None,
    session: KdeSession | None = None,
) -> dict:
    facts = facts or detect()
    session = session or KdeSession(facts)
    plan = _load_plan(plan_id)
    if confirmation != plan.get("confirmToken"):
        raise ThemesError("token de confirmação inválido")
    wallpaper_actions = [a for a in plan.get("actions", ()) if a["kind"] == "wallpaper"]
    if not wallpaper_actions:
        raise ThemesError("preview suporta somente planos de wallpaper")
    if plan.get("blockers"):
        raise ThemesError("plano contém bloqueios; revise a seleção")
    _expire_due_previews()
    applied = _apply_wallpaper_actions(session, wallpaper_actions)
    preview_id = state.new_id("preview")
    record = {
        "schema": SCHEMA,
        "kind": "preview",
        "id": preview_id,
        "planId": plan_id,
        "snapshotId": plan.get("snapshotId", ""),
        "createdAt": int(time.time()),
        "expiresAt": int(time.time()) + PREVIEW_TTL_SECONDS,
        "ttlSeconds": PREVIEW_TTL_SECONDS,
        "applied": applied,
    }
    state.save("previews", preview_id, record)
    return {
        "schema": SCHEMA,
        "previewId": preview_id,
        "planId": plan_id,
        "expiresAt": record["expiresAt"],
        "ttlSeconds": PREVIEW_TTL_SECONDS,
        "applied": applied,
        "hint": "confirme com `pz themes apply` dentro do prazo; passado o prazo, "
        "o próximo comando pz themes reverte o preview automaticamente",
    }


def _auto_expire_preview(plan_id: str) -> bool:
    """Se o plano teve preview aplicado e expirou, restaura o snapshot."""
    previews = sorted((state.root() / "previews").glob("*.json")) if (state.root() / "previews").exists() else []
    for preview_path in previews:
        try:
            record = state.load("previews", preview_path.stem)
        except ValueError:
            continue
        if record.get("planId") != plan_id or not record.get("applied"):
            continue
        if int(time.time()) <= int(record.get("expiresAt", 0)):
            continue
        _restore_snapshot(record.get("snapshotId", ""), expired=True)
        record["applied"] = False
        record["expiredRolledBack"] = True
        state.save("previews", record["id"], record)
        return True
    return False


def _expire_due_previews() -> list[dict]:
    """Reverte TODO preview vencido ainda pendente, de qualquer plano.

    A expiração era checada apenas ao reentrar no mesmo plano: um preview
    expirado sem novo comando daquele plano nunca era revertido e o wallpaper
    ficava preso no preview. Cada ponto de entrada do CLI chama esta varredura
    para cumprir a promessa do TTL.
    """
    rolled_back: list[dict] = []
    directory = state.root() / "previews"
    if not directory.is_dir():
        return rolled_back
    for preview_path in sorted(directory.glob("*.json")):
        try:
            record = state.load("previews", preview_path.stem)
        except ValueError:
            continue
        if not record.get("applied"):
            continue
        # A confirmed apply owns the wallpaper change from then on; the
        # preview that preceded it must never revert it. Only an expired
        # preview without a complete operation reverts.
        operation = _operation_for_plan(record.get("planId", ""))
        if operation is not None and operation.get("status") == "complete":
            record["applied"] = False
            record["consumedByApply"] = operation.get("id", "")
            state.save("previews", record["id"], record)
            continue
        if int(time.time()) <= int(record.get("expiresAt", 0)):
            continue
        snapshot_id = record.get("snapshotId", "")
        try:
            _restore_snapshot(snapshot_id, expired=True)
        except (ThemesError, KdeStateError, ValueError):
            continue
        record["applied"] = False
        record["expiredRolledBack"] = True
        state.save("previews", record["id"], record)
        rolled_back.append(record)
    return rolled_back


# --------------------------------------------------------------------------
# Apply
# --------------------------------------------------------------------------

def apply_plan(
    plan_id: str,
    *,
    confirmation: str = "",
    facts: HostFacts | None = None,
    session: KdeSession | None = None,
) -> dict:
    facts = facts or detect()
    session = session or KdeSession(facts)
    plan = _load_plan(plan_id)
    if confirmation != plan.get("confirmToken"):
        raise ThemesError("token de confirmação inválido")
    if plan.get("blockers"):
        raise ThemesError("plano contém bloqueios; revise a seleção")
    existing = _operation_for_plan(plan_id)
    if existing is not None:
        return {
            "schema": SCHEMA,
            "operationId": existing["id"],
            "status": existing["status"],
            "idempotent": True,
            "results": existing.get("results", []),
        }
    expired_previews = _expire_due_previews()
    if any(record.get("planId") == plan_id for record in expired_previews):
        raise ThemesError(
            "preview deste plano expirou e foi revertido automaticamente; gere um novo preview"
        )
    with state.lock():
        results: list[dict] = []
        failed = False
        failed_index = -1
        for index, action in enumerate(plan.get("actions", ())):
            if action.get("noop"):
                results.append({"featureId": action.get("featureId"), "status": "noop"})
                continue
            if action["kind"] == "feature":
                spec = feature_by_id(action["featureId"])
                adapter = adapter_for(spec) if spec else None
                if adapter is None:
                    results.append({
                        "featureId": action.get("featureId"),
                        "status": "failed",
                        "error": "adapter ainda não integrado",
                    })
                    failed = True
                    failed_index = index
                    break
                result = adapter.apply(facts, session, action)
                results.append({"featureId": action.get("featureId"), **result})
                if result.get("status") not in ("ligado", "desligado", "ok", "pausado-bateria", "pausado-jogo"):
                    failed = True
                    failed_index = index
                    break
            elif action["kind"] == "wallpaper":
                result = _apply_wallpaper_action(session, action)
                results.append({"wallpaperId": action.get("wallpaperId"), **result})
                if result.get("status") not in ("ligado", "ok"):
                    failed = True
                    failed_index = index
                    break
        operation_status = "failed" if failed else "complete"
        snapshot_id = plan.get("snapshotId", "")
        restored = False
        restore_error = ""
        if failed:
            # The compensating transaction must never mask the operation
            # record: a pruned/corrupt snapshot used to raise before
            # state.save, leaving the desktop half-applied with no operation
            # on disk and a retry that would re-apply from scratch.
            try:
                _restore_snapshot(snapshot_id, expired=False)
                restored = True
            except (ThemesError, KdeStateError, ValueError) as exc:
                restore_error = str(exc)
            # Adapters own compensations beyond config bytes - the screen
            # reader, for one, starts a live process. Best effort only.
            for index, action in enumerate(plan.get("actions", ())):
                if action["kind"] != "feature" or action.get("noop"):
                    continue
                spec = feature_by_id(action.get("featureId", ""))
                adapter = adapter_for(spec) if spec else None
                if adapter is None:
                    continue
                try:
                    adapter.rollback(facts, session, action)
                except Exception:  # noqa: BLE001 - compensação nunca máscara o veredito
                    pass
        operation_id = state.new_id("operation")
        record = {
            "schema": SCHEMA,
            "kind": "operation",
            "id": operation_id,
            "planId": plan_id,
            "snapshotId": snapshot_id,
            "createdAt": int(time.time()),
            "status": operation_status,
            "results": results,
            "failedIndex": failed_index,
            "restored": restored,
        }
        if restore_error:
            record["restoreError"] = restore_error
        state.save("operations", operation_id, record)
    return {
        "schema": SCHEMA,
        "operationId": operation_id,
        "planId": plan_id,
        "status": operation_status,
        "restored": restored,
        "results": results,
    }


def _operation_for_plan(plan_id: str) -> dict | None:
    directory = state.root() / "operations"
    if not directory.exists():
        return None
    for path in sorted(directory.glob("*.json")):
        try:
            record = state.load("operations", path.stem)
        except ValueError:
            continue
        if record.get("planId") == plan_id:
            return record
    return None


def _apply_wallpaper_action(session: KdeSession, action: dict) -> dict:
    try:
        _apply_wallpaper_actions(session, [action])
        return {"status": "ok"}
    except KdeStateError as exc:
        return {"status": "failed", "error": str(exc)}


def _apply_wallpaper_actions(session: KdeSession, actions: list[dict]) -> bool:
    for action in actions:
        target = action.get("target", "desktop")
        wallpaper_id = str(action.get("wallpaperId", ""))
        screen = int(action.get("screen", 0))
        if target == "lock":
            _apply_lock_wallpaper(session, wallpaper_id)
            continue
        plugin, params = _wallpaper_plan_params(wallpaper_id)
        if plugin == "org.kde.slideshow":
            session.write_wallpaper(screen, plugin, params, mode="MultipleImages")
        else:
            session.write_wallpaper(screen, plugin, params, mode="SingleImage")
    return True


def _apply_lock_wallpaper(session: KdeSession, wallpaper_id: str) -> None:
    plugin, params = _wallpaper_plan_params(wallpaper_id)
    if plugin == "org.kde.image":
        session.lock_screen_params(params)
        return
    raise KdeStateError("tela de bloqueio aceita somente imagem estática nesta entrega")


def _wallpaper_plan_params(wallpaper_id: str) -> tuple[str, dict]:
    item = wallpaper_by_id(wallpaper_id)
    if item is not None:
        if item.kind == "solid":
            return "org.kde.color", {"Color": item.color}
        path = Path(__file__).resolve().parents[2] / "assets" / "themes" / "wallpapers" / item.file
        return "org.kde.image", {"Image": f"file://{path}", "FillMode": "6", "Blur": "0"}
    local = Path(wallpaper_id).expanduser()
    if not local.is_file():
        raise KdeStateError(f"wallpaper ausente: {local}")
    if local.suffix.lower() in (".gif", ".webm", ".mp4", ".mkv", ".avi", ".mov"):
        raise KdeStateError("arquivo de vídeo requer a extensão de vídeo (perfil explícito)")
    return "org.kde.image", {"Image": f"file://{local}", "FillMode": "6", "Blur": "0"}


# --------------------------------------------------------------------------
# Verify
# --------------------------------------------------------------------------

def verify_operation(
    operation_id: str,
    *,
    facts: HostFacts | None = None,
    session: KdeSession | None = None,
) -> dict:
    facts = facts or detect()
    session = session or KdeSession(facts)
    operation = state.load("operations", operation_id)
    state.assert_schema(operation, "operation")
    checks: list[dict] = []
    ok = True
    for result in operation.get("results", ()):
        status = result.get("status")
        if status == "noop":
            checks.append({"item": result.get("featureId"), "status": "noop", "ok": True})
            continue
        feature_id = result.get("featureId")
        if feature_id:
            spec = feature_by_id(feature_id)
            current = feature_state(spec, facts, session) if spec else {"state": "indisponivel"}
            # Verify has to ask for the direction the operation went: a
            # successful "off" lands on desligado and used to be reported as
            # failed verification, while a failed wallpaper result fell into
            # the feature-less branch and was reported as applied.
            if status == "failed":
                passed = False
            elif status == "desligado":
                passed = current.get("state") == "desligado"
            else:
                passed = current.get("state") in ("ligado", "pausado-bateria", "pausado-jogo")
            checks.append({
                "item": feature_id,
                "status": current.get("state"),
                "ok": passed,
                "reason": current.get("reason", ""),
            })
            ok = ok and passed
        else:
            applied = status in ("ok", "ligado")
            checks.append({"item": result.get("wallpaperId"), "status": "applied" if applied else "failed", "ok": applied})
            ok = ok and applied
    return {"schema": SCHEMA, "operationId": operation_id, "ok": ok, "checks": checks}


# --------------------------------------------------------------------------
# Rollback
# --------------------------------------------------------------------------

def rollback_snapshot(
    snapshot_id: str,
    *,
    facts: HostFacts | None = None,
    session: KdeSession | None = None,
) -> dict:
    facts = facts or detect()
    session = session or KdeSession(facts)
    # Vencidos revertem também no rollback por id explícito, não só em latest.
    _expire_due_previews()
    if snapshot_id == "latest":
        snapshot_id = _latest_snapshot_id()
        if not snapshot_id:
            raise ThemesError("nenhum snapshot disponível")
    with state.lock():
        existing = _rollback_for_snapshot(snapshot_id)
        if existing is not None:
            return {
                "schema": SCHEMA,
                "rollbackId": existing["id"],
                "snapshotId": snapshot_id,
                "status": existing["status"],
                "idempotent": True,
            }
        try:
            snapshot = state.load("snapshots", snapshot_id)
        except ValueError as exc:
            raise ThemesError(f"snapshot ilegível: {exc}") from exc
        state.assert_schema(snapshot, "snapshot")
        restored = _restore_snapshot(snapshot_id, expired=False)
        rollback_id = state.new_id("rollback")
        record = {
            "schema": SCHEMA,
            "kind": "rollback",
            "id": rollback_id,
            "snapshotId": snapshot_id,
            "createdAt": int(time.time()),
            "status": "complete",
            "restored": restored,
        }
        state.save("rollbacks", rollback_id, record)
    return {
        "schema": SCHEMA,
        "rollbackId": rollback_id,
        "snapshotId": snapshot_id,
        "status": "complete",
        "restored": restored,
    }


def _rollback_for_snapshot(snapshot_id: str) -> dict | None:
    directory = state.root() / "rollbacks"
    if not directory.exists():
        return None
    for path in sorted(directory.glob("*.json")):
        try:
            record = state.load("rollbacks", path.stem)
        except ValueError:
            continue
        if record.get("snapshotId") == snapshot_id:
            return record
    return None


def _latest_snapshot_id() -> str:
    directory = state.root() / "snapshots"
    if not directory.exists():
        return ""
    snapshots = sorted(directory.glob("*.json"), key=lambda item: item.stat().st_mtime, reverse=True)
    return snapshots[0].stem if snapshots else ""


def _restore_snapshot(snapshot_id: str, *, expired: bool) -> bool:
    snapshot = state.load("snapshots", snapshot_id)
    state.assert_schema(snapshot, "snapshot")
    restored_files = False
    for record in snapshot.get("files", ()):
        backup = Path(str(record.get("backup", "")))
        target = Path(str(record.get("path", "")))
        if not backup.exists():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        # Escrever bytes direto no arquivo vivo (write_bytes trunca) disputa
        # o cache dos daemons e pode truncar o arquivo num ENOSPC. Temp no
        # mesmo diretório + replace preserva atomicidade e permissões.
        data = backup.read_bytes()
        temporary = target.with_name(f"{target.name}.{os.getpid()}.tmp")
        try:
            temporary.write_bytes(data)
            if target.exists():
                shutil.copymode(target, temporary)
            os.replace(temporary, target)
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
        restored_files = True
    if snapshot.get("wallpapers"):
        session = KdeSession(detect())
        for item in snapshot.get("wallpapers", ()):
            # Several containments report the same screen (-1 when unbound);
            # matching by screen collapsed all of them onto the first. New
            # snapshots carry the desktop array index, which addresses the
            # exact containment; old snapshots fall back to the screen match.
            desktop_index = item.get("desktopIndex")
            has_index = isinstance(desktop_index, int) and desktop_index >= 0
            if item.get("plugin") == "org.kde.slideshow":
                # O recorte captura SlidePaths; descartá-los devolvia um
                # slideshow vazio (fundo preto) ao usuário de slideshow.
                params = {key: str(value) for key, value in item.get("config", {}).items()}
                params.setdefault("SlideInterval", "3600")
                session.write_wallpaper(
                    int(item.get("screen", 0)),
                    item["plugin"],
                    params,
                    mode="MultipleImages",
                    desktop_index=desktop_index if has_index else None,
                )
            else:
                params = {key: str(value) for key, value in item.get("config", {}).items()}
                session.write_wallpaper(
                    int(item.get("screen", 0)),
                    item.get("plugin", "org.kde.image"),
                    params or {"Image": ""},
                    mode=item.get("mode", "SingleImage"),
                    desktop_index=desktop_index if has_index else None,
                )
    # Snapshot sempre registra a tela de bloqueio; host stock grava "" e o
    # gate antigo (`if lock_image:`) deixava o preview de lock permanente.
    session = KdeSession(detect())
    session.lock_screen_params({
        "Image": str(snapshot.get("lockScreen", {}).get("image", "")),
    })
    session.notify()
    return restored_files or bool(snapshot.get("wallpapers") or snapshot.get("lockScreen"))


# --------------------------------------------------------------------------
# Rescue
# --------------------------------------------------------------------------

def rescue_wallpaper(
    *,
    facts: HostFacts | None = None,
    session: KdeSession | None = None,
) -> dict:
    facts = facts or detect()
    session = session or KdeSession(facts)
    crashes = count_plasma_crashes(60)
    restored_screens: list[int] = []
    errors: list[str] = []
    try:
        screens = session.read_wallpapers()
    except KdeStateError as exc:
        screens = []
        errors.append(str(exc))
    for item in screens:
        screen = int(item.get("screen", 0))
        if screen < 0:
            # Containment sem tela real: várias entradas compartilham -1 e
            # escrever por screen colapsaria todas na primeira (e apagaria
            # wallpaper que nenhum monitor mostra).
            continue
        desktop_index = item.get("desktopIndex")
        try:
            session.write_wallpaper(
                screen,
                "org.kde.image",
                {"Image": "", "FillMode": "6", "Blur": "0"},
                mode="SingleImage",
                desktop_index=desktop_index if isinstance(desktop_index, int) else None,
            )
            restored_screens.append(screen)
        except KdeStateError as exc:
            errors.append(str(exc))
    video_disabled = False
    if crashes is not None and crashes >= 2:
        session.write_key("phasezero/themes.conf", "video", "disabledByWatchdog", "true")
        video_disabled = True
    return {
        "schema": SCHEMA,
        "crashesIn60s": crashes,
        "restoredScreens": restored_screens,
        "videoDisabled": video_disabled,
        "errors": errors,
        "ok": not errors,
    }


def _load_plan(plan_id: str) -> dict:
    try:
        plan = state.load("plans", plan_id)
    except ValueError as exc:
        raise ThemesError(f"plano ilegível: {exc}") from exc
    state.assert_schema(plan, "plan")
    if state.expired(plan, PLAN_TTL_SECONDS):
        raise ThemesError("plano expirado; gere um novo")
    return plan


def history_payload(limit: int = 15) -> dict:
    """Últimas operações e rollbacks, da mais recente para a mais antiga."""
    _expire_due_previews()
    directory = state.root() / "operations"
    if not directory.is_dir():
        return {"schema": SCHEMA, "operations": []}
    records = []
    for path in sorted(directory.glob("*.json"), key=lambda item: item.stat().st_mtime, reverse=True):
        try:
            record = state.load("operations", path.stem)
        except ValueError:
            continue
        feature_ids = [
            result.get("featureId", result.get("wallpaperId", ""))
            for result in record.get("results", ())
            if result.get("featureId") or result.get("wallpaperId")
        ]
        records.append({
            "operationId": record.get("id"),
            "planId": record.get("planId", ""),
            "snapshotId": record.get("snapshotId", ""),
            "createdAt": record.get("createdAt", 0),
            "status": record.get("status", ""),
            "restored": bool(record.get("restored")),
            "features": feature_ids,
        })
        if len(records) >= limit:
            break
    return {"schema": SCHEMA, "operations": records}
