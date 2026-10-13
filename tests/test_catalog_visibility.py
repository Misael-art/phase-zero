"""Progressive disclosure: reusar `visibility`, não reinventar (correção 6).

`catalog.py` já implementa divulgação progressiva com `visibility`
(`primary` / `standard` / `advanced`), inferida de `risk` quando não é
declarada explicitamente. Estes testes fixam as invariantes desse modelo para
que a Fase 2.1 não precise (nem consiga justificar) um sistema paralelo.

Achado da auditoria: **nenhuma** action tem `visibility` vazia ou nula — a
premissa da correção 6 ("audite todas as actions com visibility vazia") não
se sustenta contra o código. Ver docs/pr3-scope-reduction.md.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from linux.ui_native.catalog import build_catalog  # noqa: E402

VALID_VISIBILITY = {"primary", "standard", "advanced"}
VALID_RISK = {"normal", "elevated", "high"}
DESTRUCTIVE_BADGES = {"Alto risco", "Resgate"}


@pytest.fixture(scope="module")
def catalog():
    return build_catalog(ROOT)


def test_every_action_has_a_resolved_visibility(catalog):
    """O default de `_a` garante que nenhuma action nasce sem classificação."""
    unclassified = [action.id for action in catalog if not action.visibility]
    assert unclassified == [], (
        "actions sem visibility (a inferência de `_a` deveria impedir): "
        + ", ".join(unclassified)
    )


def test_visibility_and_risk_use_the_closed_vocabulary(catalog):
    for action in catalog:
        assert action.visibility in VALID_VISIBILITY, (
            f"{action.id}: visibility fora do vocabulário: {action.visibility}"
        )
        assert action.risk in VALID_RISK, f"{action.id}: risk inválido: {action.risk}"


def test_destructive_actions_are_never_shown_by_default(catalog):
    """Alto risco só aparece no painel avançado — a regra que importa."""
    exposed = [
        action.id
        for action in catalog
        if action.badge in DESTRUCTIVE_BADGES and action.visibility != "advanced"
    ]
    assert exposed == [], (
        "ações destrutivas visíveis por padrão: " + ", ".join(exposed)
    )


def test_high_risk_implies_advanced(catalog):
    exposed = [
        action.id
        for action in catalog
        if action.risk == "high" and action.visibility != "advanced"
    ]
    assert exposed == [], "risco alto fora do painel avançado: " + ", ".join(exposed)


def test_every_mutation_keeps_a_non_destructive_preview(catalog):
    """Divulgação progressiva não substitui dry-run: as duas valem juntas."""
    for action in catalog:
        if not action.mutable:
            continue
        assert action.preview_args, f"{action.id}: mutação sem preview"
        assert action.preview_args != action.args, (
            f"{action.id}: preview idêntico ao apply — não é preview"
        )


def test_inferred_visibility_follows_risk():
    """A inferência (`advanced` se risk elevated/high) continua valendo."""
    from linux.ui_native.catalog import _a

    normal = _a("t.normal", "Ajustes", "T", "d", ("doctor",), "icon")
    assert normal.risk == "normal"
    assert normal.visibility == "standard"

    elevated = _a("t.elevated", "Ajustes", "T", "d", ("doctor",), "icon", elevated=True)
    assert elevated.risk == "elevated"
    assert elevated.visibility == "advanced"

    high = _a("t.high", "Ajustes", "T", "d", ("doctor",), "icon", badge="Alto risco")
    assert high.risk == "high"
    assert high.visibility == "advanced"

    # declaração explícita vence a inferência (usada por capability.apply,
    # que é elevated mas fica em `standard` por ser protegida por token)
    override = _a(
        "t.override", "Ajustes", "T", "d", ("doctor",), "icon",
        elevated=True, visibility="standard",
    )
    assert override.risk == "elevated"
    assert override.visibility == "standard"


def test_read_only_actions_are_never_high_risk(catalog):
    wrong = [
        action.id
        for action in catalog
        if not action.mutable and action.risk == "high"
    ]
    assert wrong == [], "ação somente-leitura marcada como alto risco: " + ", ".join(wrong)


# --- CCS-003: preview de Ajustes/bundle nunca dispara o doctor -------------


def test_tune_and_support_bundle_previews_do_not_run_doctor(catalog):
    """Abrir preview de tune/support-bundle é plano da área, não doctor completo."""
    by_id = {action.id: action for action in catalog}
    for action_id in (
        "tune.browser",
        "tune.gaming",
        "tune.dev",
        "system.support-bundle",
    ):
        assert action_id in by_id, f"ação ausente no catálogo: {action_id}"
        preview = by_id[action_id].preview_args or ()
        assert "doctor" not in preview, (
            f"{action_id}: preview ainda executa pz doctor ({preview})"
        )

    for area in ("browser", "gaming", "dev"):
        preview = by_id[f"tune.{area}"].preview_args
        assert preview == ("tune", area, "--dry-run")
    assert by_id["system.support-bundle"].preview_args == ("support-bundle", "--plan")


# --- ações de manutenção do host (PR2) dentro do mesmo modelo -------------


def test_host_maintenance_actions_reuse_the_existing_model(catalog):
    by_id = {action.id: action for action in catalog}
    for action_id in (
        "host.status",
        "host.backups.list",
        "host.backups.migrate",
        "host.prune",
        "host.wipe",
    ):
        assert action_id in by_id, f"ação de manutenção ausente: {action_id}"
        assert by_id[action_id].group == "Manutenção"

    assert by_id["host.status"].visibility == "standard"
    assert by_id["host.wipe"].visibility == "advanced", "wipe não pode ser padrão"
    assert by_id["host.wipe"].badge == "Alto risco"
    # o preview do wipe não pode carregar --apply
    assert "--apply" not in by_id["host.wipe"].preview_args
    assert "--apply" not in by_id["host.backups.migrate"].preview_args


def test_maintenance_actions_are_searchable(catalog):
    """Busca global é o outro pilar do PR3 reduzido: keywords em PT."""
    by_id = {action.id: action for action in catalog}
    for action_id in ("host.status", "host.wipe", "host.prune"):
        assert by_id[action_id].keywords, f"{action_id} sem keywords de busca"
    assert "limpeza" in by_id["host.status"].keywords


# --- CCS-019: OmniRoute visível e rotulado; 9Router segue público -----------


def test_omniroute_appears_exactly_once_with_experimental_badge(catalog):
    omniroute = [action for action in catalog if "omniroute" in " ".join(action.args).casefold()]
    assert len(omniroute) == 1, f"esperado 1 card OmniRoute, há {len(omniroute)}"
    card = omniroute[0]
    assert card.badge == "Experimental"
    assert not card.mutable, "card experimental é somente leitura (status)"
    assert "9router" in card.description.casefold(), (
        "copy precisa apontar o 9Router como router público"
    )
    assert "uso bloqueado" in card.description.casefold()
    assert "grants por requisição" in card.description.casefold()


def test_9router_remains_the_public_router(catalog):
    nine = [action for action in catalog if ".9router" in action.id or "9router" in action.args]
    assert len(nine) > 5, "9Router deixou de ser a superfície principal do router"


def test_scope_reduction_is_documented():
    doc = ROOT / "docs/pr3-scope-reduction.md"
    assert doc.is_file(), "docs/pr3-scope-reduction.md ausente (correção 6)"
    text = doc.read_text(encoding="utf-8")
    assert "visibility" in text
    assert "catalog.py" in text


def test_proxy_page_labels_ide_usage_as_blocked_until_grant(catalog):
    by_id = {a.id: a for a in catalog}
    assert by_id["ai.ides"].title == "Configurar IDEs (agentes)"
    assert by_id["ai.repair"].title == "Reparar MCPs e IDEs"
    page_src = (ROOT / "linux/ui_native/pages/ai_proxies.py").read_text(encoding="utf-8")
    assert '"Uso por IDE bloqueado"' in page_src
    assert "grant por conexão" in page_src
