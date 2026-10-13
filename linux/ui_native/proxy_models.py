from __future__ import annotations

from dataclasses import dataclass, field

# User-facing proxies rendered as cards on the "Proxies IA" page. Mirrors
# proxy_ide_rows() in linux/ai/proxy-suite.sh (id, port, display name) plus the
# short catalog action suffix used for per-proxy start/stop/login buttons.
PROXY_CARDS: tuple[tuple[str, str, int, str], ...] = (
    ("kimiproxy", "Kimi", 3010, "kimi"),
    ("qwenproxy", "Qwen", 3011, "qwen"),
    ("deepsproxy", "DeepSeek", 3012, "deeps"),
    ("mimo-ai-proxy", "Mimo", 3013, "mimo"),
)

# webValidation.status → (short PT-BR label, semantic state for QSS colouring)
AUTH_LABELS: dict[str, tuple[str, str]] = {
    "authenticated": ("Sessão válida", "success"),
    "configured": ("Credenciais configuradas", "success"),
    "session-present": ("Sessão salva (não verificada)", "warning"),
    "login-running": ("Login em andamento", "warning"),
    "ready-for-login": ("Precisa de login", "warning"),
    "start-required": ("Serviço parado", "warning"),
    "dashboard-ready": ("Dashboard disponível", "success"),
    "missing-credentials": (".env incompleto", "error"),
    "gui-required": ("Requer sessão gráfica", "error"),
    "not-installed": ("Não instalado", "error"),
    "cloudflare-required": ("Deploy externo (Cloudflare)", "info"),
    "not-required": ("Sem autenticação", "info"),
    "not-applicable": ("Não se aplica", "info"),
}


@dataclass(frozen=True)
class ProxyState:
    id: str
    kind: str = ""
    port: int = 0
    installed: bool = False
    service: str = "unknown"
    api_key_configured: bool = False
    auth_required: bool = False
    auth_kind: str = ""
    auth_status: str = ""
    auth_missing: tuple[str, ...] = field(default_factory=tuple)
    env_path: str = ""

    @property
    def running(self) -> bool:
        return self.service == "active"

    @property
    def crash_looping(self) -> bool:
        return self.service == "crash-loop"

    @property
    def service_label(self) -> str:
        if not self.installed:
            return "não instalado"
        return {"active": "rodando", "inactive": "parado", "failed": "falhou", "crash-loop": "reiniciando sem parar"}.get(
            self.service, self.service or "desconhecido"
        )

    @property
    def auth_label(self) -> str:
        return AUTH_LABELS.get(self.auth_status, (self.auth_status or "—", "info"))[0]

    @property
    def auth_state(self) -> str:
        return AUTH_LABELS.get(self.auth_status, ("", "info"))[1]


@dataclass(frozen=True)
class GatewayState:
    id: str
    installed: bool = False
    healthy: bool = False
    service: str = "unknown"
    detail: str = ""
    usage_blocked: bool = False
    blocked_reason: str = ""

    @property
    def label(self) -> str:
        if self.healthy:
            return "ativo"
        if self.installed:
            return "parado"
        return "não instalado"

    @property
    def state(self) -> str:
        if self.healthy:
            return "success"
        if self.installed:
            return "warning"
        return "error"


@dataclass(frozen=True)
class IdeIntegrationState:
    env_defaults: bool = False
    env_defaults_path: str = ""
    default_proxy: str = ""
    opencode_providers: int = 0
    continue_models: int = 0
    zcode_providers: int = 0


def _as_int(value: object) -> int:
    return value if isinstance(value, int) and not isinstance(value, bool) else 0


def parse_proxy_entry(entry: object) -> ProxyState | None:
    if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
        return None
    web = entry.get("webValidation")
    web = web if isinstance(web, dict) else {}
    missing = web.get("missing")
    missing_items = tuple(str(item) for item in missing) if isinstance(missing, list) else ()
    return ProxyState(
        id=entry["id"],
        kind=str(entry.get("kind", "")),
        port=_as_int(entry.get("port")),
        installed=bool(entry.get("installed")),
        service=str(entry.get("service", "unknown")),
        api_key_configured=bool(entry.get("apiKeyConfigured")),
        auth_required=bool(web.get("required")),
        auth_kind=str(web.get("kind", "")),
        auth_status=str(web.get("status", "")),
        auth_missing=missing_items,
        env_path=str(entry.get("envPath", "")),
    )


def parse_detailed_status(parsed: object) -> tuple[dict[str, ProxyState], IdeIntegrationState]:
    """Parse `pz ai proxies detailed-status` into per-proxy and IDE state."""
    proxies: dict[str, ProxyState] = {}
    ide = IdeIntegrationState()
    if not isinstance(parsed, dict):
        return proxies, ide
    for entry in parsed.get("proxies") or []:
        state = parse_proxy_entry(entry)
        if state is not None:
            proxies[state.id] = state
    raw_ide = parsed.get("ide")
    if isinstance(raw_ide, dict):
        ide = IdeIntegrationState(
            env_defaults=bool(raw_ide.get("envDefaults")),
            env_defaults_path=str(raw_ide.get("envDefaultsPath", "")),
            default_proxy=str(raw_ide.get("defaultProxy", "")),
            opencode_providers=_as_int(raw_ide.get("opencodeProviders")),
            continue_models=_as_int(raw_ide.get("continueModels")),
            zcode_providers=_as_int(raw_ide.get("zcodeProviders")),
        )
    return proxies, ide


def parse_gateway_status(gateway_id: str, parsed: object) -> GatewayState:
    """Parse Hermes, 9Router and Odysseus status JSON envelopes."""
    if not isinstance(parsed, dict):
        return GatewayState(id=gateway_id)
    detail = ""
    if gateway_id == "9router":
        providers = parsed.get("providers")
        combos = parsed.get("combos")
        active = providers.get("active", 0) if isinstance(providers, dict) else 0
        total = combos.get("total", 0) if isinstance(combos, dict) else 0
        detail = f"{active} contas conectadas · {total} rotas prontas"
    elif gateway_id == "odysseus":
        if not bool(parsed.get("installed")) and parsed.get("podmanRootless") is False:
            detail = "Precisa de Podman rootless neste host"
        else:
            detail = str(parsed.get("endpoint", ""))
    elif gateway_id == "hermes":
        version = str(parsed.get("version", "")).strip()
        auth = parsed.get("auth") if isinstance(parsed.get("auth"), dict) else {}
        if not bool(auth.get("configured")):
            detail = "Autenticação pendente"
        else:
            detail = version or "Configuração validada"
    usage_blocked = parsed.get("usageBlocked") is True
    blocked_reason = parsed.get("blockedReason")
    if not isinstance(blocked_reason, str):
        blocked_reason = ""
    if gateway_id == "hermes" and usage_blocked:
        detail = "Uso bloqueado: grant por conexão não é aplicado a cada requisição."
    return GatewayState(
        id=gateway_id,
        installed=bool(parsed.get("installed", parsed.get("available"))),
        healthy=bool(parsed.get("healthy", parsed.get("ready"))),
        service=str(parsed.get("service", "unknown")),
        detail=detail,
        usage_blocked=usage_blocked,
        blocked_reason=blocked_reason,
    )
