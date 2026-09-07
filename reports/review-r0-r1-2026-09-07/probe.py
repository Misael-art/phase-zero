"""Independent review probes. Assertions confirm residual defects, not fixes."""
import os, sys, tempfile, subprocess, json, re, hashlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
OUT=Path(__file__).resolve().parent
if len(sys.argv)==1:
    with tempfile.TemporaryDirectory(prefix="pz-r0-probe-") as tmp:
        w=Path(tmp)
        for n in ("home","config","data","state","cache","run","bin"):(w/n).mkdir()
        for n in ("docker","systemctl","sudo","phasezero-admin","bigsudo","xdg-open","virsh","qemu-system-x86_64"):
            p=w/"bin"/n;p.write_text("#!/bin/sh\nexit 127\n");p.chmod(0o755)
        env={"PATH":str(w/"bin")+":/usr/bin:/bin:/usr/sbin:/sbin","HOME":str(w/"home"),"XDG_CONFIG_HOME":str(w/"config"),"XDG_DATA_HOME":str(w/"data"),"XDG_STATE_HOME":str(w/"state"),"XDG_CACHE_HOME":str(w/"cache"),"XDG_RUNTIME_DIR":str(w/"run"),"QT_QPA_PLATFORM":"offscreen","LANG":"C.UTF-8","TMPDIR":str(w),"DOCKER_HOST":"unix:///nonexistent-pz-review.sock"}
        print("Fixture:",w,flush=True)
        sys.exit(subprocess.run([sys.executable,__file__,"worker"],cwd=ROOT,env=env).returncode)
sys.path.insert(0,str(ROOT))
def fn(name):
    return re.search(r"^"+name+r"\(\) \{.*?^\}",(ROOT/"linux/server/homelab-stack.sh").read_text(),re.M|re.S).group(0)
def run(script):
    p=subprocess.run(["bash","-c",script],capture_output=True,text=True)
    return {"rc":p.returncode,"stdout":p.stdout,"stderr":p.stderr}
results={}
# Real down + real restore, Compose failure. No real Docker/volumes.
with tempfile.TemporaryDirectory() as tmp:
    w=Path(tmp)
    for n in ("source","mount","new"):(w/n).mkdir()
    (w/"mount/original").write_text("original");(w/"new/replacement").write_text("replacement")
    subprocess.run(["tar","-C",str(w/"new"),"-czf",str(w/"source/data.tgz"),"."],check=True)
    sha=hashlib.sha256((w/"source/data.tgz").read_bytes()).hexdigest()
    (w/"source/manifest.json").write_text(json.dumps({"project":"fixture","volumes":[{"name":"data","archive":"data.tgz","sha256":sha}]}))
    script="set -e\n"+fn("cmd_down")+"\n"+fn("cmd_restore")+"\n"+f"SOURCE='{w}/source'; MOUNT='{w}/mount'; PROJECT=fixture; YES=1; PLAN=0; PZ_HOMELAB_BACKUP_SCHEMA=1;\n"+"""
require_docker() { return 0; }; docker_reachable() { return 1; }
pz_info() { :; }; pz_error() { echo "$*" >&2; }; pz_warn() { :; }
run_compose() { echo 'injected compose down failure' >&2; return 42; }
cmd_verify_backup() { return 0; }; volume_actual_name() { echo "$1"; }
volume_owned_by_project() { return 0; }; volume_mount() { echo "$MOUNT"; }
wipe_dir_contents() { find "$1" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; }
cmd_restore
"""
    v=run(script);payload=json.loads(v["stdout"])
    results["restore_after_failed_stop"]={"rc":v["rc"],"ok":payload["ok"],"originalPreserved":(w/"mount/original").exists(),"stderr":v["stderr"]}
    assert payload["ok"] and not (w/"mount/original").exists()
# Stage reason is set in command substitution, discarded with subshell.
with tempfile.TemporaryDirectory() as tmp:
    w=Path(tmp);(w/"mount").mkdir();(w/"stage").mkdir();(w/"mount/PG_VERSION").write_text("16")
    script=fn("stage_volume_consistent")+"\n"+f"stage_out=\"$(stage_volume_consistent '{w}/mount' '{w}/stage')\"; printf '%s|%s' \"$stage_out\" \"${{STAGE_REASON:-}}\""
    v=run(script);results["stage_reason_lost"]=v;assert v["stdout"]=="staged-tar false|"
with tempfile.TemporaryDirectory() as tmp:
    w=Path(tmp);(w/"mount/wal").mkdir(parents=True);(w/"mount/chunks_head").mkdir();(w/"mount/01BLOCK/chunks").mkdir(parents=True);(w/"mount/01BLOCK/index").write_text("fixture");(w/"stage").mkdir()
    v=run(fn("stage_volume_consistent")+f"\nstage_volume_consistent '{w}/mount' '{w}/stage'")
    results["tsdb_layout_misclassified"]=v;assert v["stdout"].strip()=="staged-tar true"
from unittest.mock import patch
from PySide6.QtWidgets import QApplication
from linux.ui_native.pages.homelab import HomelabPage
from linux.ui_native.command_runner import CommandRunner
app=QApplication.instance() or QApplication([])
with patch.object(HomelabPage,"_spawn"),patch.object(HomelabPage,"refresh_hosts"),patch.object(HomelabPage,"refresh_status"):
    page=HomelabPage(ROOT,CommandRunner(ROOT),[],by_id={});page.build()
    page._host_combo.addItem("Host A","a");page._host_combo.addItem("Host B","b")
    page._host_combo.setCurrentIndex(1);page._onboard_step=1;page._pair_advance=True
    page._host_combo.setCurrentIndex(2)
    with patch.object(page,"run_cmd") as cmd:
        page._on_pair_done(0,json.dumps({"hostAlias":"a","paired":True}).encode(),b"")
        results["late_pair_a_marks_b"]={"selected":page._selected_host(),"pair":page._onboard_state.get("pair"),"pairDetail":page._onboard_state.get("pair_detail"),"step":page.onboard_step_name(),"command":cmd.call_args.args[0]}
        assert page._onboard_state["pair_detail"]["alias"]=="b" and page.onboard_step_name()=="profile"
    page.close()
plans={}
for profile in ("edge","assistant-private"):
    p=subprocess.run(["bash",str(ROOT/"linux/pz"),"server","homelab","prepare","--profile",profile,"--dry-run","--json"],capture_output=True,text=True)
    plans[profile]=json.loads(p.stdout)
results["different_profiles_same_apps"]={k:{"profile":v["profile"],"apps":v["apps"]} for k,v in plans.items()}
assert plans["edge"]["apps"]==plans["assistant-private"]["apps"]
(OUT/"probes.json").write_text(json.dumps(results,ensure_ascii=False,indent=2)+"\n")
print(json.dumps(results,ensure_ascii=False,indent=2))
