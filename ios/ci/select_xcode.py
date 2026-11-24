import pathlib
import re
import subprocess

apps = [p for p in pathlib.Path("/Applications").glob("Xcode*.app") if not any(x in p.name.lower() for x in ["beta", "_rc"])]
def version(p):
    return tuple(map(int, re.findall(r"\d+", p.name)))
candidates = [p for p in apps if version(p) and version(p)[0] >= 26]
if candidates:
    subprocess.run(["sudo", "xcode-select", "-s", str(max(candidates, key=version))], check=True)
subprocess.run(["xcodebuild", "-version"], check=True)
