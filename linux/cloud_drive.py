"""Google Drive OAuth and user-owned rclone mounts for the Linux desktop."""

from __future__ import annotations

import argparse
import configparser
from contextlib import contextmanager
import errno
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import stat
import subprocess
import tempfile
import urllib.error
import urllib.request
from uuid import uuid4


class DriveError(Exception):
    """A message suitable for the CLI or the desktop without upstream output."""

    def __init__(self, message: str, *, activation_project: str | None = None) -> None:
        super().__init__(message)
        self.activation_project = activation_project


REMOTE = "drive"
IDENTIFIER = re.compile(r"[a-f0-9]{16}")
FOLDER_ID = re.compile(r"[A-Za-z0-9_-]{1,256}")
ABOUT_URL = "https://www.googleapis.com/drive/v3/about?fields=user(permissionId,emailAddress)"


def private_dir(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise DriveError("A pasta privada do PhaseZero precisa pertencer ao usuário e ter permissão 0700.")
    return path


def private_write(path: Path, write) -> None:
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as stream:
        temp = Path(stream.name)
        try:
            write(stream)
            stream.flush()
            os.fsync(stream.fileno())
            temp.replace(path)
        finally:
            temp.unlink(missing_ok=True)


def path_text(value: str) -> str:
    return re.sub(r"\\([0-7]{3})", lambda match: chr(int(match[1], 8)), value)


def mounted_paths() -> dict[Path, tuple[str, str, set[str]]]:
    mounts = {}
    for line in Path("/proc/self/mountinfo").read_text().splitlines():
        before, after = line.split(" - ", 1)
        fields, fs = before.split(), after.split()
        mounts[Path(path_text(fields[4]))] = (fs[0], path_text(fs[1]), set(fs[2].split(",")))
    return mounts


def is_owned(entry: tuple[str, str, set[str]] | None, mount_id: str) -> bool:
    if entry is None:
        return False
    filesystem, source, options = entry
    return filesystem == "fuse.rclone" and source == f"phasezero-drive-{mount_id}" and f"user_id={os.getuid()}" in options


def contains(parent: Path, child: Path) -> bool:
    return child == parent or parent in child.parents


def disconnected(path: Path) -> bool:
    try:
        path.stat()
        return False
    except OSError as error:
        if error.errno in {errno.ENOTCONN, errno.ESTALE}:
            return True
        raise


def writable(entry: dict, account: dict) -> bool:
    return account["write"] and not entry.get("read_only", False)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def drive_api_error(error: urllib.error.HTTPError) -> DriveError:
    if error.code == 403:
        try:
            details = json.loads(error.read(65536))["error"]
            for item in [*details.get("details", []), *details.get("errors", [])]:
                if item.get("reason") not in {"SERVICE_DISABLED", "accessNotConfigured"}:
                    continue
                metadata = item.get("metadata", {})
                if metadata.get("service", "drive.googleapis.com") != "drive.googleapis.com":
                    continue
                project = re.fullmatch(r"projects/([0-9]+)", metadata.get("consumer", ""))
                return DriveError(
                    "A conta autorizou o acesso. Ative a Google Drive API no projeto do cliente OAuth e conecte a conta novamente.",
                    activation_project=project[1] if project else "",
                )
        except (ValueError, KeyError, TypeError, AttributeError, OSError):
            pass
    return DriveError("O Google Drive não confirmou a conta. Confira a autorização e tente conectar novamente.")


def account_identity(config: Path) -> tuple[str, str]:
    settings = configparser.ConfigParser(interpolation=None)
    try:
        settings.read(config, encoding="utf-8")
        token = json.loads(settings[REMOTE]["token"])
        if not token.get("access_token") or not token.get("refresh_token"):
            raise ValueError
        request = urllib.request.Request(ABOUT_URL, headers={"Authorization": "Bearer " + token["access_token"]})
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=15) as response:
            user = json.load(response)["user"]
        identity, email = user["permissionId"], user["emailAddress"]
        if not isinstance(identity, str) or not identity or not isinstance(email, str) or not email:
            raise ValueError
    except urllib.error.HTTPError as error:
        raise drive_api_error(error) from None
    except (KeyError, ValueError, OSError, TypeError, AttributeError, configparser.Error):
        raise DriveError("O Google Drive não confirmou a conta. Verifique a autorização e a Google Drive API.") from None
    return identity, email


class CloudDrive:
    def __init__(self) -> None:
        home = Path.home()
        self.config = Path(os.environ.get("XDG_CONFIG_HOME") or home / ".config") / "phasezero/cloud-drive"
        self.state = Path(os.environ.get("XDG_STATE_HOME") or home / ".local/state") / "phasezero/cloud-drive"
        runtime = os.environ.get("XDG_RUNTIME_DIR")
        self.sockets = Path(runtime) / "phasezero-drive" if runtime else self.state / "sockets"
        self.registry = self.state / "drives.json"
        self.client = self.config / "google-client.json"
        self.rclone = shutil.which("rclone")
        self.fusermount = shutil.which("fusermount3") or shutil.which("fusermount")
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("RCLONE_")}

    @contextmanager
    def transaction(self):
        lock = private_dir(self.state) / "operation.lock"
        fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise DriveError("Outra operação do Google Drive está em andamento. Tente novamente.") from None
            yield

    def load(self) -> dict:
        try:
            data = json.loads(self.registry.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return {"version": 1, "accounts": {}, "mounts": {}}
        except ValueError:
            raise DriveError("O registro das pastas virtuais está ilegível.") from None
        if (not isinstance(data, dict) or data.get("version") != 1
                or not isinstance(data.get("accounts"), dict) or not isinstance(data.get("mounts"), dict)):
            raise DriveError("A versão do registro de pastas virtuais não é compatível.")
        return data

    def save(self, data: dict) -> None:
        private_write(self.registry, lambda stream: json.dump(data, stream, ensure_ascii=False, indent=2))

    def conf(self, account_id: str) -> Path:
        if not IDENTIFIER.fullmatch(account_id):
            raise DriveError("Identificador de conta inválido.")
        return self.config / f"{account_id}.conf"

    def require_rclone(self) -> None:
        if not self.rclone:
            raise DriveError("Prepare o rclone em Recursos → Backup e nuvem.")

    def run(
        self, *args: str, failure: str, timeout: int = 25, capture: bool = True,
        timeout_message: str = "O Google Drive não respondeu a tempo. Tente novamente.",
    ) -> str:
        self.require_rclone()
        try:
            process = subprocess.run(
                [self.rclone, *args], env=self.env, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, text=True, timeout=timeout,
                encoding="utf-8", errors="replace",
            )
        except subprocess.TimeoutExpired:
            raise DriveError(timeout_message) from None
        if process.returncode:
            raise DriveError(failure)
        return process.stdout or ""

    def status(self) -> dict:
        data = self.load()
        active = mounted_paths()
        accounts = [
            {"id": key, "email": entry["email"], "write": entry["write"], "configured": self.conf(key).is_file()}
            for key, entry in data["accounts"].items()
        ]
        mounts = [
            {"id": key, **entry, "state": self.mount_state(key, entry, active),
             "write": writable(entry, data["accounts"][entry["account"]])}
            for key, entry in data["mounts"].items()
        ]
        return {
            "clientConfigured": self.client.is_file(), "rclone": bool(self.rclone),
            "fuse": bool(self.fusermount and os.access("/dev/fuse", os.R_OK | os.W_OK)),
            "accounts": accounts, "mounts": mounts,
        }

    @staticmethod
    def mount_state(mount_id: str, entry: dict, active: dict) -> str:
        current = active.get(Path(entry["local"]))
        if is_owned(current, mount_id):
            return "stale" if disconnected(Path(entry["local"])) else "mounted"
        return "occupied" if current else "unmounted"

    def set_client(self, filename: str) -> dict:
        try:
            with Path(filename).open(encoding="utf-8") as stream:
                data = json.loads(stream.read(65536))["installed"]
            client_id, secret = data["client_id"], data["client_secret"]
            if not re.fullmatch(r"[A-Za-z0-9_-]+\.apps\.googleusercontent\.com", client_id):
                raise ValueError
            if not re.fullmatch(r"[A-Za-z0-9_-]{1,256}", secret):
                raise ValueError
        except (KeyError, ValueError, OSError, TypeError):
            raise DriveError("Selecione o JSON de um cliente OAuth do tipo Aplicativo para computador.") from None
        private_dir(self.config)
        private_write(self.client, lambda stream: json.dump({"client_id": client_id, "client_secret": secret}, stream))
        return {}

    def authorize(self, account_id: str | None, write: bool) -> dict:
        self.require_rclone()
        data = self.load()
        old = self.get_entry(data, "accounts", account_id) if account_id else None
        if old and self.account_is_mounted(data, account_id):
            raise DriveError("Desmonte as pastas desta conta antes de renovar a autorização.")
        if old:
            write = old["write"]
        try:
            client = json.loads(self.client.read_text(encoding="utf-8"))
        except (FileNotFoundError, ValueError):
            raise DriveError("Configure a autorização Google antes de conectar uma conta.") from None
        key = account_id or uuid4().hex[:16]
        with tempfile.TemporaryDirectory(prefix="oauth-", dir=private_dir(self.config)) as temp:
            config = Path(temp) / "rclone.conf"
            settings = configparser.ConfigParser(interpolation=None)
            settings[REMOTE] = {"type": "drive", **client, "scope": "drive" if write else "drive.readonly"}
            private_write(config, settings.write)
            self.complete_oauth(config)
            identity, email = account_identity(config)
            if old and identity != old["identity"]:
                raise DriveError("A conta escolhida é diferente da original. Renove com a conta exibida no PhaseZero.")
            if any(entry["identity"] == identity for other, entry in data["accounts"].items() if other != key):
                raise DriveError("Esta conta Google já está conectada.")
            config.chmod(0o600)
            config.replace(self.conf(key))
        data["accounts"][key] = {"identity": identity, "email": email, "write": write}
        self.save(data)
        return {"id": key}

    def complete_oauth(self, config: Path) -> None:
        # The Drive backend keeps the selected OAuth scope in process memory.
        self.run(
            "config", "update", REMOTE, "config_is_local=true", "config_change_team_drive=false",
            "--config", str(config), timeout=300, capture=False,
            failure="A autorização não foi concluída. Confira a janela do Google e tente novamente.",
            timeout_message="A janela de autorização expirou. Clique em Conectar conta para abrir outra.",
        )

    @staticmethod
    def get_entry(data: dict, group: str, identifier: str) -> dict:
        entry = data[group].get(identifier)
        if not IDENTIFIER.fullmatch(identifier) or entry is None:
            raise DriveError("A conta ou pasta selecionada não está mais cadastrada.")
        return entry

    def account_is_mounted(self, data: dict, account_id: str) -> bool:
        active = mounted_paths()
        return any(entry["account"] == account_id and is_owned(active.get(Path(entry["local"])), key)
                   for key, entry in data["mounts"].items())

    def disconnect(self, account_id: str) -> dict:
        data = self.load()
        self.get_entry(data, "accounts", account_id)
        if any(entry["account"] == account_id for entry in data["mounts"].values()):
            raise DriveError("Remova as pastas virtuais desta conta antes de desconectá-la.")
        self.conf(account_id).unlink(missing_ok=True)
        del data["accounts"][account_id]
        self.save(data)
        return {}

    def remote_args(self, account_id: str, folder: str) -> tuple[str, ...]:
        config = self.conf(account_id)
        if not config.is_file():
            raise DriveError("Renove a autorização da conta Google.")
        if folder and not FOLDER_ID.fullmatch(folder):
            raise DriveError("Identificador de pasta do Drive inválido.")
        base = ("--config", str(config))
        return (*base, "--drive-root-folder-id", folder) if folder else base

    def folders(self, account_id: str, folder: str) -> dict:
        self.get_entry(self.load(), "accounts", account_id)
        output = self.run(
            "lsjson", f"{REMOTE}:", "--dirs-only", "--no-modtime", "--no-mimetype",
            *self.remote_args(account_id, folder),
            failure="Não foi possível consultar as pastas. Confira a rede ou renove a autorização.",
        )
        try:
            folders = [{"id": item["ID"], "name": item["Name"]} for item in json.loads(output)
                       if item["IsDir"] and FOLDER_ID.fullmatch(item.get("ID", ""))]
        except (ValueError, TypeError, AttributeError, KeyError):
            raise DriveError("O rclone retornou uma lista de pastas incompatível.") from None
        return {"folders": sorted(folders, key=lambda item: item["name"].casefold())}

    def local_target(self, value: str, mounts: dict, *, create: bool = False) -> Path:
        local = Path(value).expanduser()
        if not local.is_absolute() or any(ord(char) < 32 for char in value) or ".." in local.parts:
            raise DriveError("Escolha um caminho local absoluto e válido.")
        if any(contains(path, local) or contains(local, path) for path in (self.state, self.config, self.sockets)):
            raise DriveError("Escolha uma pasta fora do armazenamento interno do PhaseZero.")
        for entry in mounts.values():
            path = Path(entry["local"])
            if contains(path, local) or contains(local, path):
                raise DriveError("Esta pasta se sobrepõe a outra pasta virtual.")
        active = mounted_paths()
        if any(contains(local, path) or (contains(path, local) and fs.startswith("fuse."))
               for path, (fs, _, _) in active.items()):
            raise DriveError("A pasta escolhida coincide com uma montagem existente.")
        if local.resolve() != local:
            raise DriveError("Escolha uma pasta local sem links simbólicos no caminho.")
        if create:
            local.mkdir(parents=True, exist_ok=True, mode=0o700)
        if local.exists():
            if not local.is_dir() or local.stat().st_uid != os.getuid() or next(local.iterdir(), None) is not None:
                raise DriveError("Escolha uma pasta vazia que pertença ao usuário.")
        return local

    def add(self, account_id: str, folder: str, parents: list[str], label: str, local: str,
            read_only: bool = False) -> dict:
        data = self.load()
        self.get_entry(data, "accounts", account_id)
        self.remote_args(account_id, folder)
        if (any(not FOLDER_ID.fullmatch(parent) for parent in parents)
                or len(set(parents)) != len(parents) or folder in parents or (parents and not folder)):
            raise DriveError("Hierarquia de pastas do Drive inválida.")
        label = label.strip()
        if not label or len(label) > 255 or any(ord(char) < 32 for char in label):
            raise DriveError("Informe um nome válido para a pasta virtual.")
        local = self.local_target(local, data["mounts"])
        key = uuid4().hex[:16]
        data["mounts"][key] = {
            "account": account_id, "folder": folder, "parents": parents, "label": label,
            "local": str(local), "read_only": read_only,
        }
        self.save(data)
        return {"id": key}

    def socket_path(self, mount_id: str) -> Path:
        path = self.sockets / f"{mount_id}.sock"
        if len(os.fsencode(path)) >= 108 or "," in str(path):
            raise DriveError("O caminho do socket local do rclone é incompatível. Use um diretório de sessão padrão.")
        return path

    @staticmethod
    def socket_active(path: Path) -> bool:
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(1)
            try:
                client.connect(str(path))
                return True
            except (FileNotFoundError, ConnectionRefusedError):
                return False

    def mount(self, mount_id: str) -> dict:
        self.require_rclone()
        if not self.fusermount or not os.access("/dev/fuse", os.R_OK | os.W_OK):
            raise DriveError("A sessão Linux não tem FUSE disponível para montar esta pasta.")
        data = self.load()
        entry = self.get_entry(data, "mounts", mount_id)
        active = mounted_paths()
        if is_owned(active.get(Path(entry["local"])), mount_id):
            if disconnected(Path(entry["local"])):
                raise DriveError("A montagem perdeu a conexão. Desmonte a pasta e monte novamente.")
            return {}
        account = self.get_entry(data, "accounts", entry["account"])
        options = ["--read-only"]
        if writable(entry, account):
            for other_id, other in data["mounts"].items():
                if (other_id != mount_id and other["account"] == entry["account"]
                        and writable(other, account)
                        and (not other["folder"] or not entry["folder"] or other["folder"] == entry["folder"]
                             or other["folder"] in entry.get("parents", ())
                             or entry["folder"] in other.get("parents", ()))
                        and is_owned(active.get(Path(other["local"])), other_id)):
                    raise DriveError("Esta pasta já está coberta por uma montagem em edição da conta.")
            upgrade = "Atualize o rclone para a versão 1.68 ou superior para montar em edição."
            if "--unix-socket" not in self.run("rc", "--help", failure=upgrade):
                raise DriveError(upgrade)
            cache = private_dir(private_dir(self.state) / mount_id)
            private_dir(self.sockets)
            control = self.socket_path(mount_id)
            if self.socket_active(control):
                raise DriveError("Aguarde o rclone encerrar a montagem anterior e tente novamente.")
            control.unlink(missing_ok=True)
            options = [
                "--cache-dir", str(cache), "--vfs-cache-mode", "writes", "--vfs-cache-max-size", "2G",
                "--vfs-cache-min-free-space", "1G", "--vfs-cache-max-age", "1h",
                "--rc", "--rc-addr", f"unix://{control}",
            ]
        local = self.local_target(entry["local"], {k: v for k, v in data["mounts"].items() if k != mount_id}, create=True)
        self.run(
            "mount", f"{REMOTE}:", str(local), *self.remote_args(entry["account"], entry["folder"]),
            "--devname", f"phasezero-drive-{mount_id}", "--dir-perms", "0700", "--file-perms", "0600",
            "--daemon", "--daemon-wait", "20s", *options, timeout=45,
            failure="Não foi possível montar a pasta. Confira FUSE, a rede e a autorização Google.",
        )
        if not is_owned(mounted_paths().get(local), mount_id):
            raise DriveError("O Linux não confirmou a montagem da pasta.")
        return {}

    def pending_cache(self, mount_id: str) -> bool:
        # rclone persists dirty writes under vfsMeta. Unreadable metadata is retained.
        metadata = self.state / mount_id / "vfsMeta"
        if not metadata.exists():
            return False

        def unreadable(error):
            raise error

        try:
            for root, _, files in os.walk(metadata, onerror=unreadable):
                for name in files:
                    item = json.loads((Path(root) / name).read_text())
                    if item.get("Dirty") is not False:
                        return True
        except (OSError, AttributeError, ValueError):
            return True
        return False

    def unmount(self, mount_id: str) -> dict:
        data = self.load()
        entry = self.get_entry(data, "mounts", mount_id)
        local = Path(entry["local"])
        current = mounted_paths().get(local)
        if current is None:
            return {}
        if not is_owned(current, mount_id) or not self.fusermount:
            raise DriveError("O PhaseZero não controla a montagem atual desta pasta.")
        # A disconnected FUSE mount has no daemon. Keep its cache for the next mount.
        if writable(entry, data["accounts"][entry["account"]]) and not disconnected(local):
            self.check_uploads(mount_id)
        if not is_owned(mounted_paths().get(local), mount_id):
            raise DriveError("A montagem mudou. Atualize a lista antes de tentar novamente.")
        result = subprocess.run(
            [self.fusermount, "-u", "--", str(local)], stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15,
        )
        if result.returncode or is_owned(mounted_paths().get(local), mount_id):
            raise DriveError("A pasta está em uso. Feche os arquivos e tente desmontar novamente.")
        return {"pending": self.pending_cache(mount_id)}

    def check_uploads(self, mount_id: str) -> None:
        failure = "Não foi possível confirmar os envios. Mantenha a pasta montada e tente novamente."
        output = self.run("rc", "--unix-socket", str(self.socket_path(mount_id)), "vfs/stats",
                          failure=failure, timeout=5)
        try:
            stats = json.loads(output)
            values = [stats["diskCache"][key] for key in ("uploadsQueued", "uploadsInProgress", "erroredFiles")]
            if any(type(value) is not int or value < 0 for value in values):
                raise ValueError
        except (KeyError, TypeError, ValueError):
            raise DriveError(failure) from None
        if any(values):
            raise DriveError("Há arquivos em uso ou envios pendentes. Feche os arquivos e aguarde o envio.")

    def remove(self, mount_id: str) -> dict:
        data = self.load()
        entry = self.get_entry(data, "mounts", mount_id)
        if is_owned(mounted_paths().get(Path(entry["local"])), mount_id):
            raise DriveError("Desmonte esta pasta antes de removê-la do PhaseZero.")
        if writable(entry, data["accounts"][entry["account"]]) and (
            self.socket_active(self.socket_path(mount_id)) or self.pending_cache(mount_id)
        ):
            raise DriveError("O cache ainda está em uso ou contém gravações. Monte a pasta para retomar os envios.")
        cache = self.state / mount_id
        if cache.exists():
            shutil.rmtree(cache)
        del data["mounts"][mount_id]
        self.save(data)
        return {}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Conectar contas Google e montar pastas virtuais no Linux.")
    actions = parser.add_subparsers(dest="command", required=True)
    actions.add_parser("status", help="Consultar contas, FUSE e montagens.")
    actions.add_parser("set-client", help="Configurar o cliente OAuth Desktop.").add_argument("filename")
    auth = actions.add_parser("authorize", help="Conectar ou renovar uma conta pelo navegador.")
    scope = auth.add_mutually_exclusive_group()
    scope.add_argument("--account", dest="account_id")
    scope.add_argument("--write", action="store_true")
    actions.add_parser("disconnect", help="Remover a conexão local.").add_argument("account_id")
    folders = actions.add_parser("folders", help="Listar as subpastas da conta ou de uma pasta.")
    folders.add_argument("account_id")
    folders.add_argument("--folder", default="")
    add = actions.add_parser("add", help="Salvar a definição de uma pasta virtual.")
    add.add_argument("account_id")
    add.add_argument("--folder", default="")
    add.add_argument("--parent", dest="parents", action="append", default=[], help="ID de uma pasta ancestral.")
    add.add_argument("--label", required=True)
    add.add_argument("--local", required=True)
    add.add_argument("--read-only", action="store_true", help="Montar esta pasta somente para leitura.")
    for command, help_text in (
        ("mount", "Montar uma pasta registrada."), ("unmount", "Desmontar uma pasta registrada."),
        ("remove", "Remover o registro local da pasta."),
    ):
        actions.add_parser(command, help=help_text).add_argument("mount_id")
    options = vars(parser.parse_args(argv))
    command = options.pop("command").replace("-", "_")
    manager = CloudDrive()

    def cancel(_signal, _frame):
        raise KeyboardInterrupt

    if command in {"authorize", "folders"}:
        signal.signal(signal.SIGTERM, cancel)
    try:
        if os.geteuid() == 0:
            raise DriveError("Execute como usuário da sessão, sem administrador.")
        method = getattr(manager, command)
        if command == "status":
            result = method(**options)
        else:
            with manager.transaction():
                result = method(**options)
        print(json.dumps({"ok": True, **result}, ensure_ascii=False))
        return 0
    except (DriveError, OSError, subprocess.TimeoutExpired, KeyboardInterrupt, KeyError, TypeError) as error:
        response = {"ok": False}
        if isinstance(error, DriveError):
            response["message"] = str(error)
            if error.activation_project is not None:
                response["activationProject"] = error.activation_project
        elif isinstance(error, KeyboardInterrupt):
            response["message"] = "Operação cancelada."
        else:
            response["message"] = "Não foi possível concluir a operação. Confira permissões, disco e estado do rclone."
        print(json.dumps(response, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
