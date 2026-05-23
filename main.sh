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
POST_PROCESSING_PROMPT_FILE="${SCRIPT_DIR}/post_processing_prompt.md"

START_AUDIO="$SCRIPT_DIR/start.mp3"
END_AUDIO="$SCRIPT_DIR/stop.mp3"

play_notification_audio() {
  local audio_file="$1"
  local original_volume
  original_volume=$(amixer get Master | grep -o -E '[0-9]+%' | head -n 1 | sed 's/%//')

  if [ -n "$original_volume" ] && [[ "$original_volume" =~ ^[0-9]+$ ]]; then
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
  if [ -n "$WAYLAND_DISPLAY" ]; then
    printf "%s" "$text" | wl-copy
  else
    printf "%s" "$text" | xclip -selection clipboard
  fi
}

simulate_paste_shortcut() {
  if [ -n "$WAYLAND_DISPLAY" ]; then
    hyprctl dispatch sendshortcut "CTRL,V,"
  else
    xdotool key --clearmodifiers ctrl+v
  fi
}

read_post_processing_prompt() {
  if [ ! -f "$POST_PROCESSING_PROMPT_FILE" ]; then
    return 1
  fi

  cat "$POST_PROCESSING_PROMPT_FILE"
}

start_audio_recording_process() {
  arecord --format S16_LE --rate=44100 --channels=1 --buffer-size=2048 \
    | ffmpeg -f s16le -ar 44100 -ac 1 -i - \
      -af "highpass=f=80,lowpass=f=8000,dynaudnorm=f=500:g=31,volume=1.5" \
      -c:a flac -compression_level 8 "$FLAC_AUDIO_FILE" >/dev/null 2>&1 &
  echo $! >"$PID_FILE"
}

stop_audio_recording_process() {
  pkill -f "arecord --format S16_LE" >/dev/null 2>&1

  local current_pid
  if [ -f "$PID_FILE" ]; then
    current_pid=$(cat "$PID_FILE")
  fi

  if [ -n "$current_pid" ]; then
    local timeout=3000
    local counter=0
    while kill -0 "$current_pid" 2>/dev/null; do
      if [ "$counter" -ge "$timeout" ]; then
        kill -9 "$current_pid" 2>/dev/null
        break
      fi
      sleep 0.01
      counter=$((counter + 1))
    done
  fi
}

get_audio_duration() {
  local audio_file="$1"
  local audio_duration
  audio_duration=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$audio_file" 2>/dev/null)

  local seconds=${audio_duration%.*}
  local hours=$((seconds / 3600))
  local minutes=$(((seconds % 3600) / 60))
  local secs=$((seconds % 60))

  printf "%02d:%02d:%02d\n" "$hours" "$minutes" "$secs"
}

call_transcription_api() {
  local audio_file="$1"

  curl -s --compressed --connect-timeout 30 --max-time 900 \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: multipart/form-data" \
    -F file="@${audio_file}" \
    -F model="${TRANSCRIPTION_MODEL}" \
    -F temperature="0" \
    -F response_format="json" \
    "$TRANSCRIPTION_API_URL"
}

call_post_processing_api() {
  local text_to_process="$1"
  local instruction_prompt
  if ! instruction_prompt=$(read_post_processing_prompt); then
    return 1
  fi

  local user_content
  local json_payload
  user_content="${instruction_prompt}"$'\n\n'"Text to process: ${text_to_process}"
  json_payload=$(jq -n \
    --arg model "$POST_PROCESSING_MODEL" \
    --arg content "$user_content" \
    '{
      model: $model,
      messages: [
        {
          role: "user",
          content: $content
        }
      ],
      temperature: 0.05
    }')

  curl -s --compressed --connect-timeout 30 --max-time 600 \
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
    send_desktop_notification "💬 Speech recognition" "Duration: $(get_audio_duration "$FLAC_AUDIO_FILE")"
  } &

  file_size=$(stat -f%z "$FLAC_AUDIO_FILE" 2>/dev/null || stat -c%s "$FLAC_AUDIO_FILE" 2>/dev/null)
  if [ -z "$file_size" ] || [ "$file_size" -lt 100 ]; then
    send_desktop_notification "❌ Recording error" "Audio file is too small or empty" &
    rm -f "$FLAC_AUDIO_FILE" "$PID_FILE"
    exit 1
  fi

  output=$(call_transcription_api "$FLAC_AUDIO_FILE")

  if [ -z "$output" ] || ! echo "$output" | jq -e '.text' >/dev/null 2>&1; then
    send_desktop_notification "❌ Transcription failed" "API timeout or error" &
    rm -f "$FLAC_AUDIO_FILE" "$PID_FILE"
    exit 1
  fi

  output=$(jq -r '.text' <<<"$output" 2>/dev/null | awk '{$1=$1};1')

  if [ "$ENABLE_POST_PROCESSING" = true ] && [ -n "$output" ]; then
    send_desktop_notification "📝 Post-processing text" "Using model: ${POST_PROCESSING_MODEL}" &
    if processed_output=$(call_post_processing_api "$output"); then
      processed_text=$(echo "$processed_output" | jq -r '.choices[0].message.content' 2>/dev/null | awk '{$1=$1};1')
      if [ -n "$processed_text" ]; then
        output="$processed_text"
      fi
    else
      send_desktop_notification "❌ Prompt error" "Missing post-processing prompt file" &
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
