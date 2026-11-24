import json
import os
import pathlib
import time
import urllib.parse
import urllib.request
import jwt

required = ["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8", "APPLE_TEAM_ID"]
missing = [name for name in required if not os.environ.get(name)]
if missing:
    raise SystemExit("GitHub 저장소 Secrets에 설정 필요: " + ", ".join(missing))
kid = os.environ["ASC_KEY_ID"]
keydir = pathlib.Path.home() / "private_keys"
keydir.mkdir(mode=0o700, exist_ok=True)
keyfile = keydir / f"AuthKey_{kid}.p8"
keyfile.write_text(os.environ["ASC_KEY_P8"])
keyfile.chmod(0o600)
now = int(time.time())
token = jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}, os.environ["ASC_KEY_P8"], algorithm="ES256", headers={"kid": kid})
base = "https://api.appstoreconnect.apple.com/v1"
def request(path, body=None):
    req = urllib.request.Request(base + path, data=json.dumps(body).encode() if body else None,
                                headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"}, method="POST" if body else "GET")
    with urllib.request.urlopen(req, timeout=60) as response:
        return json.load(response)
for ident in ["kr.b-612.aroundview"]:
    query = "/bundleIds?" + urllib.parse.urlencode({"filter[identifier]": ident})
    found = request(query)["data"]
    if not any(item["attributes"]["identifier"] == ident for item in found):
        request("/bundleIds", {"data": {"type": "bundleIds", "attributes": {"identifier": ident, "name": ident.replace(".", " "), "platform": "IOS"}}})
    verified = request(query)["data"]
    assert any(item["attributes"]["identifier"] == ident for item in verified), "번들 등록 읽기 검증 실패"
    print("번들 확인:", ident)
apps = request("/apps?" + urllib.parse.urlencode({"filter[bundleId]": "kr.b-612.aroundview"}))["data"]
if not apps:
    raise SystemExit("App Store Connect에서 kr.b-612.aroundview 번들 ID로 새 앱을 만들어 주세요. 번들 ID는 등록 완료했습니다.")
print("App Store Connect 앱 확인:", apps[0]["id"])
