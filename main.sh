#!/usr/bin/env bash

set -e

SCRIPT_DIR=$(dirname "$0")
TMP_DIR="/tmp"
PID_FILE="${TMP_DIR}/recorder.pid"
FLAC_AUDIO_FILE="${TMP_DIR}/input.flac"

API_KEY=$(cat "${SCRIPT_DIR}/.api")

TRANSCRIPTION_MODEL="whisper-large-v3"
TRANSCRIPTION_API_URL="https://api.groq.com/openai/v1/audio/transcriptions"

ENABLE_POST_PROCESSING=true
POST_PROCESSING_MODEL="openai/gpt-oss-120b"
POST_PROCESSING_API_URL="https://api.groq.com/openai/v1/chat/completions"
POST_PROCESSING_INSTRUCTION_PROMPT="You are a text processing AI. Your only task is to follow the user's instruction. Do not add any explanations, greetings, or any text other than the final, processed text. The output must be ONLY the final text."
POST_PROCESSING_TASK_PROMPT="Correct grammar, spelling, and punctuation, and format it into paragraphs. It is crucial that you identify the original language of the text and provide the corrected text in that same language."

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

  curl -s --compressed --connect-timeout 10 --max-time 60 \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: multipart/form-data" \
    -F file="@${audio_file}" \
    -F model="${TRANSCRIPTION_MODEL}" \
    "$TRANSCRIPTION_API_URL"
}

call_post_processing_api() {
  local text_to_process="$1"

  local raw_user_content
  raw_user_content=$(printf "%s\n\nTask: %s\n\nText to process: %s" "$POST_PROCESSING_INSTRUCTION_PROMPT" "$POST_PROCESSING_TASK_PROMPT" "$text_to_process")

  local escaped_user_content
  escaped_user_content=$(echo "$raw_user_content" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')

  local json_payload
  json_payload=$(printf '{
    "model": "%s",
    "messages": [
      {
        "role": "user",
        "content": "%s"
      }
    ]
  }' "$POST_PROCESSING_MODEL" "$escaped_user_content")

  curl -s --compressed --connect-timeout 10 --max-time 180 \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$json_payload" \
    "$POST_PROCESSING_API_URL"
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

  output=$(call_transcription_api "$FLAC_AUDIO_FILE")

  output=$(jq -r '.text' <<<"$output" 2>/dev/null | awk '{$1=$1};1')

  if [ "$ENABLE_POST_PROCESSING" = true ] && [ -n "$output" ]; then
    send_desktop_notification "📝 Post-processing text" &
    processed_output=$(call_post_processing_api "$output")
    processed_text=$(echo "$processed_output" | jq -r '.choices[0].message.content' 2>/dev/null | awk '{$1=$1};1')
    if [ -n "$processed_text" ]; then
      output="$processed_text"
    fi
  fi

  if [ -n "$output" ]; then
    copy_text_to_clipboard "$output"
    send_desktop_notification "📋 Sent to clipboard" &
    sleep 0.02
    simulate_paste_shortcut
  fi

  rm -f "$FLAC_AUDIO_FILE" "$PID_FILE"
fi
