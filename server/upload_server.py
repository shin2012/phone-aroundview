#!/usr/bin/env python3
"""폰어라운드 주행 기록 받는 서버 (표준 라이브러리만 사용).

앱(RecordingStore.swift)과 맞춘 규약 — 모두 `Authorization: Bearer <토큰>` 필요:

  GET  /api/ping                                   → {"ok": true}
  GET  /api/sessions/<이름>                        → {"files": {파일: 받은 크기}, "done": bool}
  PUT  /api/sessions/<이름>/files/<파일>?offset=N   본문을 N 위치에 이어 씀 → {"size": 새 크기}
                                                     N 이 지금 크기와 다르면 409 {"size": 지금 크기}
  POST /api/sessions/<이름>/done  {"files": {파일: 크기}}  크기 확인 후 완료 표시 → 분석 실행

환경 변수: AV_UPLOAD_TOKEN (필수), AV_DATA_DIR (기본 ./data/sessions),
          AV_BIND (기본 172.22.0.1), AV_PORT (기본 8945), AV_ON_DONE (완료 후 실행할 명령, {dir} 치환)
"""
import hmac
import json
import os
import re
import shlex
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

TOKEN = os.environ.get("AV_UPLOAD_TOKEN", "")
DATA = Path(os.environ.get("AV_DATA_DIR", Path(__file__).resolve().parent.parent / "data" / "sessions"))
BIND = os.environ.get("AV_BIND", "172.22.0.1")
PORT = int(os.environ.get("AV_PORT", "8945"))
ON_DONE = os.environ.get("AV_ON_DONE", "")
MAX_CHUNK = 64 * 1024 * 1024
MAX_FILE = 8 * 1024 * 1024 * 1024

SESSION_RE = re.compile(r"^\d{8}_\d{6}$")
FILE_RE = re.compile(r"^[A-Za-z0-9_\-][A-Za-z0-9_.\-]{0,63}$")
locks: dict[str, threading.Lock] = {}
locks_guard = threading.Lock()


def file_lock(key: str) -> threading.Lock:
    with locks_guard:
        return locks.setdefault(key, threading.Lock())


def log(*a):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), *a, flush=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "aroundview-upload/1"

    def log_message(self, format, *args):  # 기본 접근 로그 대신 짧게
        pass

    def reply(self, code: int, obj: dict):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authed(self) -> bool:
        h = self.headers.get("Authorization", "")
        if TOKEN and h.startswith("Bearer ") and hmac.compare_digest(h[7:].encode(), TOKEN.encode()):
            return True
        self.reply(401, {"error": "unauthorized"})
        return False

    def route(self):
        u = urlparse(self.path)
        parts = [p for p in u.path.split("/") if p]
        return parts, parse_qs(u.query)

    def session_dir(self, name: str) -> Path | None:
        if not SESSION_RE.match(name):
            self.reply(400, {"error": "bad session name"})
            return None
        return DATA / name

    # ---- GET
    def do_GET(self):
        parts, _ = self.route()
        if parts == ["health"]:
            return self.reply(200, {"ok": True})
        if not self.authed():
            return
        if parts == ["api", "ping"]:
            return self.reply(200, {"ok": True})
        if len(parts) == 3 and parts[:2] == ["api", "sessions"]:
            d = self.session_dir(parts[2])
            if d is None:
                return
            files = {}
            if d.is_dir():
                for f in d.iterdir():
                    if f.is_file() and FILE_RE.match(f.name):
                        files[f.name] = f.stat().st_size
            return self.reply(200, {"files": files, "done": (d / ".complete").exists()})
        if parts == ["api", "sessions"]:
            out = []
            if DATA.is_dir():
                for d in sorted(DATA.iterdir()):
                    if d.is_dir() and SESSION_RE.match(d.name):
                        out.append({"name": d.name, "done": (d / ".complete").exists()})
            return self.reply(200, {"sessions": out})
        self.reply(404, {"error": "not found"})

    # ---- PUT (조각 이어 쓰기)
    def do_PUT(self):
        if not self.authed():
            return
        parts, q = self.route()
        if not (len(parts) == 5 and parts[:2] == ["api", "sessions"] and parts[3] == "files"):
            return self.reply(404, {"error": "not found"})
        d = self.session_dir(parts[2])
        if d is None:
            return
        fname = parts[4]
        if not FILE_RE.match(fname):
            return self.reply(400, {"error": "bad file name"})
        try:
            offset = int(q.get("offset", ["0"])[0])
            length = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            return self.reply(400, {"error": "bad offset/length"})
        if length < 0 or length > MAX_CHUNK:
            return self.reply(413, {"error": "chunk too large"})
        if offset + length > MAX_FILE:
            return self.reply(413, {"error": "file too large"})
        d.mkdir(parents=True, exist_ok=True)
        path = d / fname
        with file_lock(str(path)):
            cur = path.stat().st_size if path.exists() else 0
            if offset != cur:
                # 본문은 읽어서 버림 (연결 재사용)
                remaining = length
                while remaining > 0:
                    chunk = self.rfile.read(min(remaining, 1 << 20))
                    if not chunk:
                        break
                    remaining -= len(chunk)
                return self.reply(409, {"size": cur})
            with open(path, "ab") as fh:
                remaining = length
                while remaining > 0:
                    chunk = self.rfile.read(min(remaining, 1 << 20))
                    if not chunk:
                        break
                    fh.write(chunk)
                    remaining -= len(chunk)
            size = path.stat().st_size
        if remaining > 0:
            # 끊긴 조각: 받은 데까지만 남기고 앱이 이어서 보냄
            log("short", d.name, fname, size)
        return self.reply(200, {"size": size})

    # ---- POST done
    def do_POST(self):
        if not self.authed():
            return
        parts, _ = self.route()
        if not (len(parts) == 4 and parts[:2] == ["api", "sessions"] and parts[3] == "done"):
            return self.reply(404, {"error": "not found"})
        d = self.session_dir(parts[2])
        if d is None:
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(min(length, 1 << 20)) or b"{}")
            want = body.get("files", {})
        except (ValueError, json.JSONDecodeError):
            return self.reply(400, {"error": "bad json"})
        bad = {}
        for name, size in want.items():
            p = d / name
            have = p.stat().st_size if FILE_RE.match(name) and p.exists() else -1
            if have != size:
                bad[name] = {"want": size, "have": have}
        if bad:
            return self.reply(409, {"error": "size mismatch", "files": bad})
        (d / ".complete").write_text(json.dumps({"at": time.time(), "files": want}))
        total = sum(want.values())
        log("done", d.name, f"{total / 1e6:.1f}MB", len(want), "files")
        if ON_DONE:
            cmd = ON_DONE.replace("{dir}", shlex.quote(str(d)))
            subprocess.Popen(cmd, shell=True, stdout=open(d / ".on_done.log", "w"), stderr=subprocess.STDOUT,
                             start_new_session=True)
        return self.reply(200, {"ok": True, "bytes": total})


def main():
    if not TOKEN:
        sys.exit("AV_UPLOAD_TOKEN 이 필요합니다")
    DATA.mkdir(parents=True, exist_ok=True)
    srv = ThreadingHTTPServer((BIND, PORT), Handler)
    srv.daemon_threads = True
    log(f"listening {BIND}:{PORT} → {DATA}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
