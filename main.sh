#!/usr/bin/env bash

set -e

SCRIPT_DIR=$(dirname "$0")
TMP_DIR="/tmp"
PID_FILE="${TMP_DIR}/recorder.pid"
FLAC_AUDIO_FILE="${TMP_DIR}/input.flac"

API_KEY=$(cat "${SCRIPT_DIR}/.api")
MODEL="whisper-large-v3-turbo"

START_AUDIO="$SCRIPT_DIR/start.mp3"
END_AUDIO="$SCRIPT_DIR/stop.mp3"

if [ -f "$PID_FILE" ] && ps -p "$(cat "$PID_FILE")" >/dev/null; then
  pkill -f "arecord --format S16_LE"

  pid=$(cat "$PID_FILE")
  timeout=600
  counter=0
  while ps -p "$pid" >/dev/null; do
    if [ "$counter" -ge "$timeout" ]; then
      kill -9 "$pid"
      break
    fi
    sleep 0.01
    counter=$((counter + 1))
  done

  mpg123 "$END_AUDIO" >/dev/null 2>&1 &
  notify-send "💬 Speech recognition" &

  output=$(curl -s https://api.groq.com/openai/v1/audio/transcriptions \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: multipart/form-data" \
    -F file="@${FLAC_AUDIO_FILE}" \
    -F model="${MODEL}")
  text=$(jq -r '.text' <<<"$output" | xargs)

  if [ -n "$text" ]; then
    printf "%s" "$text" | wl-copy
    notify-send "📋 Sent to clipboard" &
    sleep 0.05
    hyprctl dispatch sendshortcut "CTRL,V,"
  fi

  rm "$FLAC_AUDIO_FILE" "$PID_FILE"
else
  mpg123 "$START_AUDIO" >/dev/null 2>&1 &
  notify-send "🔴 Start recording" &

  arecord --format S16_LE --rate=16000 | ffmpeg -i - -c:a flac -compression_level 1 -f flac "$FLAC_AUDIO_FILE" >/dev/null 2>&1 &
  echo $! >"$PID_FILE"
fi
