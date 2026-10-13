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
        env={"PATH":str(w/"bin")+":/usr/bin:/bin:/usr/sbin:/sbin","HOME":str(w/"home"),"XDG_CONFIG_HOME":str(w/"config"),"XDG_DATA_HOME":str(w/"data"),"XDG_STATE_HOME":str(w/"state"),"XDG_CACHE_HOME":str(w/"cache"),"XDG_RUNTIME_DIR":str(w/"run"),"QT_QPA_PLATFORM":"offscreen","USER":"fixture","LOGNAME":"fixture","LANG":"C.UTF-8","TMPDIR":str(w),"DOCKER_HOST":"unix:///nonexistent-pz-review.sock"}
        print("Fixture:",w,flush=True)
        sys.exit(subprocess.run([sys.executable,__file__,"worker"],cwd=ROOT,env=env).returncode)
sys.path.insert(0,str(ROOT))
from unittest.mock import patch
from PySide6.QtWidgets import QApplication
from linux.ui_native.pages.homelab import HomelabPage
from linux.ui_native.main_window import MainWindow
from linux.ui_native.command_runner import CommandRunner
from linux.ui_native.app import apply_theme
app=QApplication.instance() or QApplication([])
results={}
with patch.object(HomelabPage,"_spawn"),patch.object(HomelabPage,"refresh_hosts"),patch.object(HomelabPage,"refresh_status"):
    page=HomelabPage(ROOT,CommandRunner(ROOT),[],by_id={});page.build()
    page._onboard_confirmed=True;page._onboard_state["plan_host"]=""
    plans=[]
    for memory in (16000,15999):
        env=dict(os.environ);env["PZ_HOMELAB_RAM_TOTAL_OVERRIDE"]=str(memory)
        proc=subprocess.run(["bash",str(ROOT/"linux/pz"),"server","homelab","prepare","--profile","edge","--dry-run","--json"],env=env,capture_output=True,text=True)
        plans.append(json.loads(proc.stdout))
    with patch.object(page,"run_cmd") as run:
        for plan in plans:page._on_apply_plan_done(0,json.dumps(plan).encode(),b"")
        results["volatile_plan"]={"memory":[p["budget"]["availableMB"] for p in plans],"sameApps":plans[0]["apps"]==plans[1]["apps"],"verdicts":[p["budget"]["verdict"] for p in plans],"executeCalled":run.called,"message":page._state_label.text()}
        assert run.called
    print("plan-probe complete",flush=True)
    page._onboard_step=3;page._onboard_confirmed=False
    page.show();page._refresh_onboard_label();app.processEvents()
    page._page_scroll.ensureWidgetVisible(page._onboard_confirm);app.processEvents()
    results["confirmation_visibility"]={"hidden":page._onboard_confirm.isHidden(),"enabled":page._onboard_confirm.isEnabled(),"visibleRegionEmpty":page._onboard_confirm.visibleRegion().isEmpty()}
    page._onboard_next.click()
    results["review_button"]={"confirmed":page._onboard_confirmed,"step":page.onboard_step_name()}
    assert not page._onboard_confirmed and page.onboard_step_name()=="review"
    page.close()
print("confirm-probe complete",flush=True)
apply_theme(app,"dark")
with patch.object(MainWindow,"_host_summary"),patch("linux.ui_native.status_loader.StatusLoader.fetch_action"),patch.object(HomelabPage,"_spawn"),patch.object(HomelabPage,"refresh_hosts"):
    win=MainWindow(ROOT);win.show()
    for width,height in ((800,600),(1280,800),(800,600)):
        win.resize(width,height)
        for category in ("Início","Homelab","Windows VM"):
            print("render",category,width,flush=True)
            win.show_category(category)
            for _ in range(8):app.processEvents()
            from PySide6.QtWidgets import QScrollArea
            from PySide6.QtCore import QPoint,QRect
            page=win.registry.page_for(category)
            scrolls=page.findChildren(QScrollArea)
            measurement={"horizontalMaxima":[x.horizontalScrollBar().maximum() for x in scrolls]}
            if hasattr(page,"power_button"):
                scroll=page._page_scroll;btn=page.power_button
                rect=QRect(btn.mapTo(scroll.viewport(),QPoint(0,0)),btn.size())
                measurement["powerFullyInViewport"]=scroll.viewport().rect().contains(rect)
                measurement["powerRight"]=rect.right();measurement["viewportRight"]=scroll.viewport().rect().right()
            results.setdefault("geometry",{})[category+str(width)]=measurement
            win.grab().save(str(OUT/(category.replace(" ","-")+f"-{width}.png")))
    win.close()
(OUT/"probes.json").write_text(json.dumps(results,indent=2,ensure_ascii=False)+"\n")
print(results,flush=True)
