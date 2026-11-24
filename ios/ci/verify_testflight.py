import json
import os
import pathlib
import time
import urllib.parse
import urllib.request
import jwt

now = int(time.time())
token = jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}, os.environ["ASC_KEY_P8"], algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"]})
def read(path):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com/v1" + path, headers={"Authorization": "Bearer " + token})
    with urllib.request.urlopen(req, timeout=60) as response:
        return json.load(response)
app = read("/apps?" + urllib.parse.urlencode({"filter[bundleId]": "kr.b-612.aroundview"}))["data"][0]
build_number = os.environ["BUILD_NUMBER"]
out = pathlib.Path(os.environ["RUNNER_TEMP"]) / "verification"
out.mkdir(exist_ok=True)
for attempt in range(40):
    platform = os.environ.get("PLATFORM", "IOS")
    result = read("/builds?" + urllib.parse.urlencode({"filter[app]": app["id"], "filter[version]": build_number, "filter[preReleaseVersion.platform]": platform, "include": "preReleaseVersion,buildBetaDetail"}))
    (out / f"testflight-{platform}.json").write_text(json.dumps(result, indent=2))
    if result["data"]:
        build = result["data"][0]
        state = build["attributes"]["processingState"]
        print(platform, "빌드", build_number, state)
        if state == "VALID":
            print("처리 완료, 빌드 ID:", build["id"])
            break
        if state in ["FAILED", "INVALID"]:
            raise SystemExit("TestFlight 처리 실패: " + state)
    time.sleep(20)
else:
    raise SystemExit("처리 상태 확인 시간 초과. 업로드와 설치 가능 상태를 구분해야 합니다.")
