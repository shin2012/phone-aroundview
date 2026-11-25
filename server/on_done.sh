#!/bin/bash
# 업로드 완료 후 실행: 분석(replay.py) → 텔레그램으로 요약 보고
# 사용: on_done.sh <기록 폴더>   (환경: TG_BOT_TOKEN, TG_CHAT_ID)
set -u
DIR="$1"
APP="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.hermes/tools/ffmpeg-9.0.1-linux-arm64/bin:$PATH"
"$APP/.venv/bin/python" "$APP/tools/replay.py" "$DIR" > "$DIR/.replay.log" 2>&1
STATUS=$?
[ -z "${TG_BOT_TOKEN:-}" ] && exit 0
API="https://api.telegram.org/bot${TG_BOT_TOKEN}"
if [ $STATUS -eq 0 ] && [ -f "$DIR/analysis/report.md" ]; then
  TEXT="[폰어라운드 기록 도착]
$(sed '1,2d' "$DIR/analysis/report.md")
서버 경로: $DIR/analysis"
else
  TEXT="[폰어라운드 기록 도착] $(basename "$DIR") — 분석 실패
$(tail -5 "$DIR/.replay.log")"
fi
curl -s -X POST "$API/sendMessage" --data-urlencode "chat_id=${TG_CHAT_ID}" --data-urlencode "text=${TEXT}" > /dev/null
for img in "$DIR/analysis/track.png" "$DIR/analysis/speed.png"; do
  [ -f "$img" ] && curl -s -F "chat_id=${TG_CHAT_ID}" -F "photo=@${img}" "$API/sendPhoto" > /dev/null
done
exit 0
