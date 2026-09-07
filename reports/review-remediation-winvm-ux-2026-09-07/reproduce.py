"""Read-only product review. Run with isolated HOME/XDG and QT offscreen.
Assertions reproduce defects; they are NOT acceptance tests for a correction.
"""
import json, re, subprocess, tempfile, sys
from pathlib import Path
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT))
from PySide6.QtWidgets import QApplication
from linux.ui_native.pages.homelab import HomelabPage
from linux.ui_native.command_runner import CommandRunner
from linux.ui_native.catalog import build_catalog
from linux.ui_native.main_window import MainWindow
from linux.ui_native.app import apply_theme

def fn(path,name):
    text=(ROOT/path).read_text()
    return re.search(r"^"+name+r"\(\) \{.*?^\}",text,re.M|re.S).group(0)

def bash(script):
    r=subprocess.run(["bash","-c",script],capture_output=True,text=True)
    return {"rc":r.returncode,"stdout":r.stdout,"stderr":r.stderr}

app=QApplication.instance() or QApplication([])
results={}
with patch.object(HomelabPage,"_spawn"),patch.object(HomelabPage,"refresh_status"),patch.object(HomelabPage,"refresh_hosts"):
    page=HomelabPage(ROOT,CommandRunner(ROOT),[],by_id={});page.build()
    result=subprocess.run(["bash",str(ROOT/"linux/pz"),"server","homelab","prepare","--dry-run","--json"],capture_output=True)
    payload=json.loads(result.stdout)
    parsed=page._first_json_line(result.stdout)
    assert payload["dryRun"] and parsed=={}
    results["onboarding_multiline"]={"cli_rc":result.returncode,"valid_json":True,"ui_parsed":parsed}
    page._onboard_step=1;page.onboard_ingest_pair(False);page.onboard_advance()
    assert page.onboard_step_name()=="profile"
    results["pair_failed_advances"]={"next_step":page.onboard_step_name()}
    page._onboard_confirmed=True
    page._onboard_state["review_plan"]=json.dumps(payload,sort_keys=True)
    page._host_combo.addItem("fixture B","fixture-b");page._host_combo.setCurrentIndex(1)
    with patch.object(page,"run_cmd") as run:
        page._on_apply_plan_done(0,json.dumps(payload).encode(),b"")
        assert run.called
        results["confirmation_survives_host_change"]={"host":page._selected_host(),"dispatched":run.call_args.args[0]}
    page.close()
script=fn("linux/windows-vm/windows-vm-session.sh","direct_boot_graphics_flag")+"\nlauncher_graphics_probe() { echo '{\"eligible\":true}'; }\ndirect_boot_graphics_flag\n"
flag=bash(script)["stdout"].strip()
script=fn("linux/windows-vm/windows-vm.sh","guard_graphics_profile")+"\npz_error() { echo \"$*\" >&2; }; GRAPHICS_PROFILE=virtio-gl; LIBVIRT_DOMAIN=''; RAW_QEMU=1; EXPLICIT_GRAPHICS=1; GRAPHICS_EXPERIMENTAL=0; guard_graphics_profile\n"
result=bash(script);assert result["rc"]==1 and "experimental" in result["stderr"]
results["boot_graphics_contract"]={"session_flag":flag,"launcher_guard":result}
# Only the extracted restore function; fake Docker/project/volume helpers.
with tempfile.TemporaryDirectory(prefix="pz-restore-review-") as d:
    w=Path(d);(w/"source").mkdir();(w/"mount").mkdir();(w/"new").mkdir()
    (w/"mount/original.txt").write_text("original");(w/"new/replacement.txt").write_text("replacement")
    subprocess.run(["tar","-C",str(w/"new"),"-czf",str(w/"source/data.tgz"),"."],check=True)
    import hashlib
    sha=hashlib.sha256((w/"source/data.tgz").read_bytes()).hexdigest()
    (w/"source/manifest.json").write_text(json.dumps({"schemaVersion":"1","project":"fixture","volumes":[{"name":"data","archive":"data.tgz","sha256":sha}]}))
    script=fn("linux/server/homelab-stack.sh","cmd_restore")+"\n"+f"SOURCE='{w}/source'; MOUNT='{w}/mount'; PROJECT=fixture; YES=1; PLAN=0; DRY_RUN=0; PZ_HOMELAB_BACKUP_SCHEMA=1; CONFIRM_FILE='';\n"+"""
pz_error() { echo "$*" >&2; }; pz_warn() { echo "$*" >&2; }; pz_info() { :; }
cmd_verify_backup() { echo '{"verified":true}'; }
require_docker() { return 0; }; volume_actual_name() { echo "$1"; }; volume_owned_by_project() { return 0; }
volume_mount() { echo "$MOUNT"; }; cmd_down() { return 0; }
wipe_dir_contents() { find "$1" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; }
cp() { case "$*" in *pz-restore.*/stage/.*) return 42;; *) command cp "$@";; esac; }
cmd_restore
"""
    result=bash(script)
    results["restore_partial_copy"]={"rc":result["rc"],"stdout":result["stdout"],"original_preserved":(w/"mount/original.txt").exists(),"remaining_files":[p.name for p in (w/"mount").iterdir()]}
    assert result["rc"]==1 and not (w/"mount/original.txt").exists()
# UI render: no status commands or host probes. Defaults reflect a fresh user.
apply_theme(app,"dark")
with patch.object(MainWindow,"_host_summary"),patch("linux.ui_native.status_loader.StatusLoader.fetch_action"),patch.object(HomelabPage,"_spawn"),patch.object(HomelabPage,"refresh_hosts"):
    window=MainWindow(ROOT);window.resize(1280,800);window.show()
    for category,name in [("Início","home"),("Windows VM","windows"),("Homelab","homelab")]:
        window.show_category(category);app.processEvents();window.grab().save(str(Path(__file__).parent/(name+".png")))
    results["ui"]={"advanced_default":window.preferences.advanced_mode,"sidebar_categories":len(window.sidebar_buttons)}
    window.close()
(Path(__file__).parent/"reproductions.json").write_text(json.dumps(results,indent=2,ensure_ascii=False)+"\n")
print(json.dumps(results,indent=2,ensure_ascii=False))
