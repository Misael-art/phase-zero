from __future__ import annotations

import re
from dataclasses import dataclass


_CHECK_RE = re.compile(
    r"^\[(PASS|WARN|FAIL|ERROR|INFO)]\s+([^:]+):\s*(.*?)(?:\s+—\s+(.*))?$"
)

_GROUPS = (
    (("MEM", "DISK", "FS", "CPU", "GPU"), "Hardware"),
    (("NET",), "Conexão"),
    (("SVC", "DOCKER"), "Serviços"),
    (("SD", "UX", "ST", "BOOT"), "Steam e jogos"),
    (("SEC",), "Segurança"),
    (("AI", "DEV"), "IA e desenvolvimento"),
)

_COPY = {
    "Total RAM >= 4GB": "Memória total suficiente",
    "Available RAM >= 1GB": "Memória disponível suficiente",
    "Swap >= 2GB": "Memória de apoio configurada",
    "root partition usage": "Espaço livre do sistema",
    "Root filesystem type": "Formato do disco do sistema",
    "CPU temperature < 85°C": "Temperatura do processador",
    "CPU temperature": "Temperatura do processador",
    "CPU load (1m) < cores": "Carga do processador equilibrada",
    "AMD GPU detected": "Placa de vídeo AMD detectada",
    "GPU device in sysfs": "Placa de vídeo disponível ao sistema",
    "Internet connectivity": "Conexão com a internet",
    "Tailscale connected": "Acesso remoto Tailscale",
    "Steam Deck hardware": "Hardware Steam Deck reconhecido",
    "Steam client available": "Steam disponível",
    "Gamescope available": "Modo console disponível",
    "MangoHud available": "Monitor de desempenho disponível",
    "GameMode launcher available": "Otimização de jogos disponível",
    "Virtual keyboard available": "Teclado virtual disponível",
    "Docker daemon accessible": "Servidor de aplicativos disponível",
    "Docker Compose": "Gerenciador de serviços disponível",
    "UFW firewall active": "Firewall ativo",
    "SSH server running": "Acesso remoto SSH",
    "docker running": "Docker (aplicativos em contêiner)",
    "sshd running": "Acesso remoto SSH",
    "NetworkManager running": "Gerenciador de rede",
    "bluetooth running": "Bluetooth",
}

_DETAIL_COPY = {
    "inactive": "parado",
    "sensor unavailable": "sensor indisponível",
    "not configured on Steam Deck": "não configurado neste Steam Deck",
    "not connected or not installed": "desconectado ou não instalado",
    "not installed (optional)": "não instalado (opcional)",
    "disabled (optional)": "desligado (opcional)",
    "enabled but inactive": "deveria iniciar com o sistema, mas está parado",
    "not found": "não encontrado",
}

_USAGE_RE = re.compile(r"^(/\S*) usage$")
_USED_RE = re.compile(r"^(\d+%) used$")
_TEMP_RE = re.compile(r"^(\d+)°C(?: \(critical (\d+)°C\))?$")


@dataclass(frozen=True)
class HealthCheck:
    status: str
    check_id: str
    title: str
    detail: str
    group: str

    @property
    def state(self) -> str:
        return {
            "PASS": "success",
            "WARN": "warning",
            "INFO": "info",
            "FAIL": "error",
            "ERROR": "error",
        }.get(self.status, "info")

    @property
    def needs_attention(self) -> bool:
        return self.status in {"WARN", "FAIL", "ERROR"}


def _group_for(check_id: str) -> str:
    upper = check_id.upper()
    for prefixes, title in _GROUPS:
        if upper.startswith(prefixes):
            return title
    return "Sistema"


def _friendly_title(title: str) -> str:
    if title in _COPY:
        return _COPY[title]
    usage = _USAGE_RE.match(title)
    if usage:
        return f"Espaço livre em {usage.group(1)}"
    replacements = (
        (" installed", " instalado"),
        (" available", " disponível"),
        (" running", " em execução"),
        (" active", " ativo"),
        (" connected", " conectado"),
    )
    value = title
    for source, target in replacements:
        value = value.replace(source, target)
    return value[:1].upper() + value[1:]


def _friendly_detail(detail: str) -> str:
    if detail in _DETAIL_COPY:
        return _DETAIL_COPY[detail]
    used = _USED_RE.match(detail)
    if used:
        return f"{used.group(1)} ocupado"
    temp = _TEMP_RE.match(detail)
    if temp and temp.group(2):
        return f"{temp.group(1)} °C (limite crítico do sensor: {temp.group(2)} °C)"
    if temp:
        return f"{temp.group(1)} °C"
    return detail


def health_summary(checks: list[HealthCheck]) -> str:
    """One plain sentence for the verdict, shared by dialogs and pages."""
    failures = sum(check.state == "error" for check in checks)
    warnings = sum(check.status == "WARN" for check in checks)
    if not failures and not warnings:
        return "Tudo certo. Nenhum item precisa de atenção."
    parts = []
    if failures:
        parts.append(f"{failures} erro{'s' if failures != 1 else ''}")
    if warnings:
        parts.append(f"{warnings} aviso{'s' if warnings != 1 else ''}")
    return "Encontramos " + " e ".join(parts) + ". Veja abaixo o que revisar; nada foi alterado."


def parse_health_checks(value: object) -> list[HealthCheck]:
    if not isinstance(value, list):
        return []
    checks: list[HealthCheck] = []
    for item in value:
        match = _CHECK_RE.match(str(item).strip())
        if match is None:
            continue
        status, check_id, title, detail = match.groups()
        checks.append(HealthCheck(
            status=status,
            check_id=check_id.strip(),
            title=_friendly_title(title.strip()),
            detail=_friendly_detail((detail or "").strip()),
            group=_group_for(check_id),
        ))
    return checks


def suggested_action_id(check: HealthCheck) -> str:
    if check.check_id == "UX05":
        return "steamdeck.keyboard.repair"
    if check.check_id in {"UX06", "UX07"}:
        return "steamdeck.hotkeys"
    if check.check_id.startswith("NET"):
        return "system.repair-plan"
    if check.check_id.startswith(("MEM", "CPU", "DISK", "FS", "GPU", "SVC", "DOCKER")):
        return "system.repair-plan"
    return "system.repair-plan"
