"""Read-only audit of product code; mutations are restricted to fresh fixtures.

Run from any directory with python3. No downloads, installs, or real services.
Passing assertions confirm a defect in the audited revision, not product health.
"""
from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile
import hashlib
import io
import tarfile

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).parent / "evidence"
OUT.mkdir(exist_ok=True)
WORK = Path(tempfile.mkdtemp(prefix="pz-audit-repro-"))
BIN = WORK / "bin"
BIN.mkdir()
# An allowlisted PATH models absent workload dependencies without uninstalling
# anything. Every executable resolves to an existing system utility.
for name in ("bash", "sh", "jq", "python3", "date", "dirname", "mkdir", "chmod",
             "mktemp", "rm", "cat", "awk", "sed", "grep", "head", "tail", "sort",
             "cut", "wc", "stat", "install", "mv", "cp", "ln", "find", "flock",
             "sha256sum", "tar", "gzip", "realpath", "readlink", "getent", "id", "uname",
             "hostname", "timeout", "openssl", "tr", "basename", "touch", "sleep"):
    source = shutil.which(name)
    if source:
        (BIN / name).symlink_to(source)

env = {k: v for k, v in os.environ.items() if not k.startswith(
    ("PZ_", "PHASEZERO_", "AI_MEMORY_", "HERMES_", "XDG_", "DBUS_"))}
env.update(HOME=str(WORK / "home"), PATH=str(BIN),
           XDG_CONFIG_HOME=str(WORK / "home/.config"),
           XDG_DATA_HOME=str(WORK / "home/.local/share"),
           XDG_STATE_HOME=str(WORK / "state"), XDG_RUNTIME_DIR=str(WORK / "run"),
           PZ_HOMELAB_STATE=str(WORK / "homelab"),
           PZ_HOMELAB_WINVM_STATUS_FILE=str(WORK / "winvm.json"),
           PZ_HOMELAB_RAM_TOTAL_OVERRIDE="32768", PZ_HOMELAB_APPS_NO_DOCKER="1",
           PZ_AI_PROXY_ROOT=str(WORK / "proxies"), PZ_LOCAL_BIN=str(WORK / "local-bin"))
for name in ("home", "run", "state", "homelab"):
    (WORK / name).mkdir()
(WORK / "winvm.json").write_text('{"libvirtState":"shut off","currentMarker":"no"}')
print(json.dumps({"fixture_paths": str(WORK), "PATH": str(BIN)}, indent=2), flush=True)
results = []


def run(name, argv, extra=None):
    child = {**env, **(extra or {})}
    p = subprocess.run(argv, cwd=ROOT, env=child, text=True, capture_output=True, timeout=90)
    row = {"probe": name, "exitCode": p.returncode, "stdout": p.stdout, "stderr": p.stderr}
    results.append(row)
    (OUT / "reproductions.json").write_text(json.dumps(results, indent=2, ensure_ascii=False).replace(str(WORK), "<fixture>") + "\n")
    return p


def shell(name, body, extra=None):
    return run(name, ["bash", "-c", body], extra)


p = run("clean-host-repair", ["bash", "linux/pz", "server", "homelab", "repair", "--json"])
repair = json.loads(p.stdout)
assert p.returncode == 0 and repair["after"]["ready"] is False
assert repair["after"]["stack"]["docker"]["installed"] is False

p = run("enable-without-docker", ["bash", "linux/pz", "server", "homelab", "apps", "enable", "vaultwarden", "--json"])
enabled = json.loads(p.stdout)
assert p.returncode == 0 and enabled["ok"] and enabled["enabled"] and not enabled["started"]

p = shell("profile-swallowed-failure", '''
source linux/server/apply-common.sh
bash() { echo fixture-child-failed >&2; return 42; }
PZ_SERVER_INSTALL_BOOT=0 pz_server_apply --homelab --no-boot
''')
assert p.returncode == 0 and "server profile applied" in p.stdout

p = shell("health-without-healthcheck", '''
source linux/server/homelab-status.sh
running_containers() { echo phasezero-fixture; }
container_health() { echo none; }
health_proofs
''')
assert json.loads(p.stdout)["healthy"] is True

p = shell("proxy-build-failure-accepted", '''
set -- status kimiproxy
source linux/ai/proxy-suite.sh >/dev/null
clone_approved_snapshot() {
  mkdir -p "$3/.git"
  printf '%s\\n' '{"scripts":{"start":"node dist/index.js"}}' > "$3/package.json"
  printf '%s\\n' '{}' > "$3/package-lock.json"
}
run_npm() { echo fixture-npm-failed >&2; return 42; }
apply_loopback_patch() { return 0; }
if install_one kimiproxy https://example.invalid/fixture.git 3010 node; then
  echo AUDIT_ACCEPTED_FAILED_BUILD
else
  echo AUDIT_REJECTED_FAILED_BUILD
fi
''')
assert "AUDIT_ACCEPTED_FAILED_BUILD" in p.stdout and "fixture-npm-failed" in p.stderr

p = shell("router-runtime-without-npm", '''
set -- status
source linux/ai/9router-manager.sh >/dev/null
ensure_node_runtime
''')
assert p.returncode != 0 and "npm required" in p.stderr

# Exercise the actual app disable path with a failed Compose operation, never
# Docker. A fixture wrapper reports CLI/daemon presence but refuses removal.
docker = BIN / "docker"
docker.write_text('''#!/bin/sh
case "$*" in
  info|"compose version"|"compose version --short") exit 0 ;;
  *" rm -sf "*) echo fixture-compose-rm-failed >&2; exit 42 ;;
esac
exit 0
''')
docker.chmod(0o755)
p = run("disable-failed-compose", ["bash", "linux/pz", "server", "homelab", "apps", "disable", "vaultwarden", "--json"], {"PZ_HOMELAB_APPS_NO_DOCKER": "0"})
disabled = json.loads(p.stdout)
assert p.returncode == 0 and disabled["ok"] and not disabled["stopped"]
assert "compose rm failed" in disabled["reason"]
docker.unlink()

(WORK / "volumes").mkdir()
p = run("backup-all-volumes-missing", ["bash", "linux/pz", "server", "homelab", "backup", "--dest", str(WORK / "backup")], {
    "PZ_HOMELAB_VOLUMES_OVERRIDE": "vaultwarden_data",
    "PZ_HOMELAB_VOLUME_MOUNT_OVERRIDE": str(WORK / "volumes")})
backup = json.loads(p.stdout)
assert p.returncode == 0 and backup["ok"] and backup["volumes"] == []

p = run("verify-empty-backup", ["bash", "linux/pz", "server", "homelab", "backup", "verify", "--source", str(WORK / "backup")])
assert p.returncode == 0 and json.loads(p.stdout)["verified"]

restore_source = WORK / "restore-source"
restore_source.mkdir()
volume = WORK / "volumes/vaultwarden_data"
volume.mkdir()
(volume / "stale-file.txt").write_text("File absent from backup; must disappear on exact restore")
for filename, content in (("vaultwarden_data.tgz", b"backed-up-data"), ("unexpected.tgz", b"not-in-manifest")):
    with tarfile.open(restore_source / filename, "w:gz") as tar:
        info = tarfile.TarInfo("data.txt")
        info.size = len(content)
        tar.addfile(info, io.BytesIO(content))
manifest = {"schemaVersion": 2, "volumes": [{"name": "vaultwarden_data", "archive": "vaultwarden_data.tgz", "sha256": hashlib.sha256((restore_source / "vaultwarden_data.tgz").read_bytes()).hexdigest()}]}
(restore_source / "manifest.json").write_text(json.dumps(manifest))
p = run("restore-extracts-unlisted-archive", ["bash", "linux/pz", "server", "homelab", "restore", "--source", str(restore_source), "--yes"], {
    "PZ_HOMELAB_VOLUMES_OVERRIDE": "vaultwarden_data",
    "PZ_HOMELAB_VOLUME_MOUNT_OVERRIDE": str(WORK / "volumes")})
assert p.returncode == 0, p.stdout + p.stderr
assert (WORK / "volumes/unexpected/data.txt").read_text() == "not-in-manifest"
assert (volume / "stale-file.txt").exists()
results.append({"probe": "restore-filesystem-proof", "exitCode": 0,
                "stdout": "Unlisted archive extracted; stale file retained. Both inside fixture only.", "stderr": ""})

# Missing required services are not included in the aggregate readiness test.
p = shell("ready-with-one-unchecked-container", '''
source linux/server/homelab-status.sh
running_containers() { echo phasezero-fixture; }
container_health() { echo none; }
build_status | jq '{ready,healthy,active,reasons}'
''')
assert json.loads(p.stdout)["ready"] is True

for row in results:
    row["stdout"] = row["stdout"].replace(str(WORK), "<fixture>")
    row["stderr"] = row["stderr"].replace(str(WORK), "<fixture>")
(OUT / "reproductions.json").write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\n")
print(f"{len(results)} defect reproductions confirmed; evidence/reproductions.json")
print("Fixture retained for review:", WORK)
