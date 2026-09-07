"""Run only isolated reproductions and screenshots. No production workloads."""
import os, pathlib, subprocess, sys, tempfile
HERE=pathlib.Path(__file__).resolve().parent
ROOT=HERE.parents[1]
with tempfile.TemporaryDirectory(prefix="pz-review-reproduce-") as name:
    w=pathlib.Path(name)
    for folder in ("home","config","data","state","cache","run","bin"):
        (w/folder).mkdir()
    for tool in ("docker","systemctl","phasezero-admin","bigsudo","sudo","xdg-open","startplasma-wayland","startplasma-x11","qemu-system-x86_64","virsh"):
        p=w/"bin"/tool;p.write_text("#!/bin/sh\nexit 77\n");p.chmod(0o755)
    env={"PATH":str(w/"bin")+":/usr/bin:/bin:/usr/sbin:/sbin", "LANG":"C.UTF-8", "QT_QPA_PLATFORM":"offscreen", "HOME":str(w/"home"),"XDG_CONFIG_HOME":str(w/"config"),"XDG_DATA_HOME":str(w/"data"),"XDG_STATE_HOME":str(w/"state"),"XDG_CACHE_HOME":str(w/"cache"),"XDG_RUNTIME_DIR":str(w/"run"),"TMPDIR":str(w),"DOCKER_HOST":"unix:///nonexistent-pz-review.sock","PZ_WINDOWS_VM_SESSION_DESKTOP_FALLBACK":"0"}
    print("Fixture paths:",w,flush=True)
    result=subprocess.run([sys.executable,str(HERE/"reproduce.py")],cwd=ROOT,env=env)
    sys.exit(result.returncode)
