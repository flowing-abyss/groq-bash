#!/usr/bin/env bash

set -e

SCRIPT_DIR=$(dirname "$0")
TMP_DIR="/tmp"
PID_FILE="${TMP_DIR}/recorder.pid"
FLAC_AUDIO_FILE="${TMP_DIR}/input.flac"

TRANSCRIPTION_API_KEY=$(cat "${SCRIPT_DIR}/.api")
TRANSCRIPTION_MODEL="whisper-large-v3"
TRANSCRIPTION_API_URL="https://api.groq.com/openai/v1/audio/transcriptions"

START_AUDIO="$SCRIPT_DIR/start.mp3"
END_AUDIO="$SCRIPT_DIR/stop.mp3"

play_notification_audio() {
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

send_desktop_notification() {
  local title="$1"
  local message="$2"
  notify-send "$title" "$message" &
}

copy_text_to_clipboard() {
  local text="$1"
  printf "%s" "$text" | wl-copy
}

simulate_paste_shortcut() {
  hyprctl dispatch sendshortcut "CTRL,V,"
}

start_audio_recording_process() {
  arecord --format S16_LE --rate=16000 --buffer-size=1024 \
    | ffmpeg -f s16le -ar 16000 -ac 1 -i - -c:a flac -compression_level 1 "$FLAC_AUDIO_FILE" >/dev/null 2>&1 &
  echo $! >"$PID_FILE"
}

stop_audio_recording_process() {
  pkill -f "arecord --format S16_LE" >/dev/null 2>&1

  local current_pid=$(cat "$PID_FILE")
  local timeout=600
  local counter=0
  while kill -0 "$current_pid" 2>/dev/null; do
    if [ "$counter" -ge "$timeout" ]; then
      kill -9 "$current_pid" 2>/dev/null
      break
    fi
    sleep 0.01
    counter=$((counter + 1))
  done
}

call_transcription_api() {
  local audio_file="$1"
  local api_key="$2"
  local model="$3"
  local api_url="$4"

  curl -s --compressed --connect-timeout 10 --max-time 60 \
    -H "Authorization: Bearer ${api_key}" \
    -H "Content-Type: multipart/form-data" \
    -F file="@${audio_file}" \
    -F model="${model}" \
    "$api_url"
}

if [ ! -f "$PID_FILE" ] || ! ps -p "$(cat "$PID_FILE")" >/dev/null 2>&1; then
  {
    play_notification_audio "$START_AUDIO" &
    send_desktop_notification "🔴 Start recording"
  } &

  start_audio_recording_process
else
  stop_audio_recording_process

  {
    play_notification_audio "$END_AUDIO" &
    send_desktop_notification "💬 Speech recognition"
  } &

  output=$(call_transcription_api "$FLAC_AUDIO_FILE" "$TRANSCRIPTION_API_KEY" "$TRANSCRIPTION_MODEL" "$TRANSCRIPTION_API_URL")

  text=$(jq -r '.text' <<<"$output" 2>/dev/null | awk '{$1=$1};1')

  if [ -n "$text" ]; then
    copy_text_to_clipboard "$text"
    send_desktop_notification "📋 Sent to clipboard" &
    sleep 0.02
    simulate_paste_shortcut
  fi

  rm -f "$FLAC_AUDIO_FILE" "$PID_FILE"
fi
