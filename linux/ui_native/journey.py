"""Journey vocabulary shared by the Homelab Player (UX-005/007/009).

Pure functions only: no Qt, no I/O. The page renders what these return, and
the tests exercise the same code path the operator sees.

The rules encoded here:

* UX-005 — installing is not simulating a budget. Simple mode lists only
  profiles with an install recipe; budget-only profiles are opt-in and are
  announced as simulation in the interface, not in a log line.
* UX-007 — a failure states its cause and the next action in product
  language. Reading the log is never a requirement to recover.
* UX-009 — installing ends with the solution open. "Running" is not
  "ready": a container without a passing functional probe is still being
  prepared, and first access has to be configured before the solution is
  offered as ready.
"""

from __future__ import annotations

# Journey states, in order.
NOT_INSTALLED = "nao-instalado"
PREPARING = "preparando"
CONFIGURE_ACCESS = "configurar-acesso"
READY = "pronto"

JOURNEY_ORDER = (NOT_INSTALLED, PREPARING, CONFIGURE_ACCESS, READY)

_HEADLINE = {
    NOT_INSTALLED: "Não instalado",
    PREPARING: "Preparando",
    CONFIGURE_ACCESS: "Configurar acesso",
    READY: "Pronto para usar",
}

_ACTION = {
    NOT_INSTALLED: "Instalar",
    PREPARING: "Preparando…",
    CONFIGURE_ACCESS: "Configurar acesso",
    READY: "Abrir solução",
}


def journey_headline(state: str) -> str:
    return _HEADLINE.get(state, _HEADLINE[NOT_INSTALLED])


def journey_action_label(state: str) -> str:
    return _ACTION.get(state, _ACTION[NOT_INSTALLED])


def app_journey(app: dict, status: dict | None = None,
                first_access_done: bool = False) -> tuple[str, str]:
    """Return ``(state, explanation)`` for one catalog app.

    ``status`` is the ``homelab-status`` payload; its ``functionalProbes``
    are what separates "the container is up" from "the solution answers".
    """
    status = status or {}
    key = str(app.get("key") or "")
    if not bool(app.get("enabled")):
        return NOT_INSTALLED, "Ainda não instalado neste servidor."
    if not bool(app.get("running")):
        return PREPARING, "Instalado — aguardando o serviço subir."

    probes = status.get("functionalProbes")
    probes = probes if isinstance(probes, dict) else {}
    passed = [str(k) for k in (probes.get("passed") or [])]
    failed = [str(k) for k in (probes.get("failed") or [])]
    if key in failed:
        return PREPARING, "Rodando, mas ainda não responde — aguarde ou repare."
    if key not in passed:
        return PREPARING, "Rodando; resposta do serviço ainda não confirmada."

    if not first_access_done:
        return CONFIGURE_ACCESS, first_use_summary(app)
    return READY, "Responde e o primeiro acesso já foi configurado."


def first_use_steps(app: dict) -> list[str]:
    """First-use steps for the interface.

    The catalog carries the CLI copy in ``steps`` (English, same language as
    the rest of ``pz``) and the interface copy in ``stepsPtBr``. The Player
    is Brazilian Portuguese, so it prefers ``stepsPtBr`` and only falls back
    to ``steps`` for an app that has not been translated yet.
    """
    first_use = app.get("firstUse")
    if not isinstance(first_use, dict):
        return []
    for field in ("stepsPtBr", "steps"):
        steps = first_use.get(field)
        if isinstance(steps, list) and steps:
            return [str(s) for s in steps]
    return []


def first_use_summary(app: dict) -> str:
    steps = first_use_steps(app)
    if steps:
        return steps[0]
    return "Abra a solução e conclua o primeiro acesso."


def open_url(app: dict) -> str:
    return str(app.get("openUrl") or app.get("url") or "")


# ---------------------------------------------------------------- UX-005
def split_profiles(profiles: list) -> tuple[list, list]:
    """Split the profile catalog into ``(installable, budget_only)``."""
    installable: list = []
    budget_only: list = []
    for profile in profiles:
        if not isinstance(profile, dict):
            continue
        (installable if profile.get("installable") else budget_only).append(profile)
    return installable, budget_only


def plan_is_simulation(payload: dict) -> bool:
    """True when the reviewed plan carries a budget-only profile.

    Such a plan still prepares the server and installs the catalog
    defaults, which is NOT what the chosen profile promised. Executing it
    unchanged would answer a goal the operator did not ask for.
    """
    return bool(payload.get("profile")) and payload.get("profileInstallable") is False


def plan_simulation_refusal(payload: dict) -> str:
    profile = str(payload.get("profile") or "")
    services = [str(s) for s in (payload.get("profileServices") or [])]
    note = str(payload.get("profileNote") or "sem receita de instalação")
    served = ", ".join(services) if services else "os serviços do perfil"
    return (
        f"'{profile}' só reserva recursos: {served} não têm instalação disponível "
        f"({note}). Instalar agora prepararia o servidor com os aplicativos padrão, "
        "que não é o que você escolheu."
    )


def plan_summary(payload: dict) -> list[str]:
    """The plan in product language (UX-007).

    The same document the advanced view shows as JSON, said in terms of
    what will happen to the machine. Callers render these lines in the
    interface; the raw document stays an advanced detail.
    """
    lines: list[str] = []
    host = str(payload.get("hostAlias") or payload.get("host") or "local")
    lines.append("Servidor: este computador" if host == "local" else f"Servidor: {host}")

    apps = [str(a) for a in (payload.get("apps") or [])]
    if apps:
        lines.append(f"Instala {len(apps)} aplicativos: " + ", ".join(apps) + ".")
    else:
        lines.append("Nenhum aplicativo será instalado por este plano.")

    access = str(payload.get("access") or "")
    if access:
        lines.append(
            "Acesso: só por este computador (127.0.0.1)." if access == "local"
            else f"Acesso: {access}."
        )

    budget = payload.get("budget") if isinstance(payload.get("budget"), dict) else {}
    if budget.get("budgetMB") is not None:
        lines.append(
            f"Memória reservada: {budget.get('budgetMB')} MiB de "
            f"{budget.get('availableMB')} MiB livres."
        )

    steps = [str(s) for s in (payload.get("steps") or [])]
    if steps:
        lines.append(f"Etapas: {len(steps)} — " + " → ".join(steps) + ".")

    if plan_is_simulation(payload):
        lines.append(plan_simulation_refusal(payload))
    return lines


def profile_simulation_note(profile: dict) -> str:
    note = str(profile.get("installNote") or "sem receita de instalação")
    return (
        f"Simulação de recursos: '{profile.get('title') or profile.get('key')}' "
        f"reserva orçamento e não instala nada ({note}). "
        "Instale soluções pelo catálogo de aplicativos."
    )


# ---------------------------------------------------------------- UX-007
_CAUSES = (
    ("no space left", "Espaço em disco acabou durante a instalação.",
     "Libere espaço e tente de novo."),
    ("disk quota", "Espaço em disco acabou durante a instalação.",
     "Libere espaço e tente de novo."),
    ("cannot connect to the docker daemon", "O serviço de contêineres não está ativo.",
     "Ligue o Docker e tente de novo."),
    ("docker daemon", "O serviço de contêineres não está ativo.",
     "Ligue o Docker e tente de novo."),
    ("permission denied", "PhaseZero não tem permissão para esta etapa.",
     "Autorize o acesso administrativo e tente de novo."),
    ("unauthorized", "As credenciais foram recusadas.",
     "Refaça a autenticação e tente de novo."),
    ("authentication required", "As credenciais foram recusadas.",
     "Refaça a autenticação e tente de novo."),
    ("manifest unknown", "A imagem desta solução não foi encontrada no registro.",
     "Atualize o catálogo e tente de novo."),
    ("timeout", "O download demorou demais e foi interrompido.",
     "Verifique a conexão e tente de novo."),
    ("temporary failure in name resolution", "Sem acesso à internet para baixar a solução.",
     "Verifique a rede e tente de novo."),
    ("connection refused", "O servidor recusou a conexão.",
     "Confirme que o host está ligado e tente de novo."),
)

_GENERIC = ("Esta etapa não foi concluída.", "Tente de novo; os detalhes técnicos estão em Saída.")


def failure_cause(text: str) -> tuple[str, str]:
    """Map raw command output to ``(cause, next_action)`` in product language."""
    lowered = (text or "").casefold()
    for needle, cause, action in _CAUSES:
        if needle in lowered:
            return cause, action
    return _GENERIC


def failure_banner_text(text: str) -> str:
    cause, action = failure_cause(text)
    return f"{cause} {action}"
