#!/usr/bin/env bash

set -e

SCRIPT_DIR=$(dirname "$0")
TMP_DIR="/tmp"
PID_FILE="${TMP_DIR}/recorder.pid"
FLAC_AUDIO_FILE="${TMP_DIR}/input.flac"

API_KEY=$(cat "${SCRIPT_DIR}/.api")
MODEL="whisper-large-v3"

START_AUDIO="$SCRIPT_DIR/start.mp3"
END_AUDIO="$SCRIPT_DIR/stop.mp3"

play_audio() {
  local audio_file="$1"
  local original_volume=$(amixer get Master | grep -o -E '[0-9]+%' | head -n 1 | sed 's/%//')

  if [ -n "$original_volume" ]; then
    local target_volume=$((original_volume * 60 / 100))
    amixer set Master "${target_volume}%" >/dev/null 2>&1
    mpg123 "$audio_file" >/dev/null 2>&1
    amixer set Master "${original_volume}%" >/dev/null 2>&1
  else
    mpg123 "$audio_file" >/dev/null 2>&1
  fi
}

if [ -f "$PID_FILE" ] && ps -p "$(cat "$PID_FILE")" >/dev/null 2>&1; then
  pkill -f "arecord --format S16_LE" >/dev/null 2>&1

  current_pid=$(cat "$PID_FILE")
  timeout=600
  counter=0
  while kill -0 "$current_pid" 2>/dev/null; do
    if [ "$counter" -ge "$timeout" ]; then
      kill -9 "$current_pid" 2>/dev/null
      break
    fi
    sleep 0.01
    counter=$((counter + 1))
  done

  {
    play_audio "$END_AUDIO" &
    notify-send "💬 Speech recognition"
  } &

  output=$(curl -s --compressed --connect-timeout 10 --max-time 60 \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: multipart/form-data" \
    -F file="@${FLAC_AUDIO_FILE}" \
    -F model="${MODEL}" \
    https://api.groq.com/openai/v1/audio/transcriptions)

  text=$(jq -r '.text' <<<"$output" 2>/dev/null | awk '{$1=$1};1')

  if [ -n "$text" ]; then
    printf "%s" "$text" | wl-copy
    notify-send "📋 Sent to clipboard" &
    sleep 0.02
    hyprctl dispatch sendshortcut "CTRL,V,"
  fi

  rm -f "$FLAC_AUDIO_FILE" "$PID_FILE"
else
  {
    play_audio "$START_AUDIO" &
    notify-send "🔴 Start recording"
  } &

  arecord --format S16_LE --rate=16000 --buffer-size=1024 \
    | ffmpeg -f s16le -ar 16000 -ac 1 -i - -c:a flac -compression_level 1 "$FLAC_AUDIO_FILE" >/dev/null 2>&1 &
  echo $! >"$PID_FILE"
fi
