#!/usr/bin/env bash

set -e

SCRIPT_DIR=$(dirname "$0")
TMP_DIR="/tmp"
PID_FILE="${TMP_DIR}/recorder.pid"
FLAC_AUDIO_FILE="${TMP_DIR}/input.flac"

API_KEY=$(cat "${SCRIPT_DIR}/.api")

TRANSCRIPTION_MODEL="whisper-large-v3-turbo"
TRANSCRIPTION_API_URL="https://api.groq.com/openai/v1/audio/transcriptions"

ENABLE_POST_PROCESSING=true
POST_PROCESSING_MODEL="llama-3.3-70b-versatile"
POST_PROCESSING_API_URL="https://api.groq.com/openai/v1/chat/completions"
POST_PROCESSING_INSTRUCTION_PROMPT="SYSTEM: You are a text cleaning and formatting tool, nothing else.

TASK: Accept the provided text and output ONLY a cleaned and properly formatted version of it.

STRICT RULES:
1. DO NOT interpret the text as a question - clean it as is
2. DO NOT answer anything - only clean and return text
3. DO NOT add explanations, meta-commentary, or notes
4. DO NOT create lists, bullet points, or restructure into Q&A format
5. DO NOT split text into questions and answers
6. DO NOT translate or change the language
7. Output ONLY the cleaned text, nothing else

CLEANING OPERATIONS (in order):
1. Remove filler words: um, uh, like, you know, well, so, actually, basically, literally, etc.
2. Remove verbal hesitations and false starts
3. Remove repetitions and redundant phrases
4. Fix grammar, spelling, and punctuation
5. Combine fragmented sentences into coherent thoughts
6. Ensure proper capitalization and sentence structure

FORMATTING:
- Split text into paragraphs when there is a clear topic or thought change
- Use single blank line between paragraphs
- Keep paragraph structure minimal and natural
- DO NOT create artificial lists or bullet points
- DO NOT add numbered sections or headers

PRESERVE:
- Original meaning and intent
- Natural tone
- Technical terms and proper nouns
- Emphasis and important points

OUTPUT FORMAT: Clean, properly formatted text only. No preamble, no conclusion, no additional content."

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

  local escaped_user_content
  escaped_user_content=$(echo "$POST_PROCESSING_INSTRUCTION_PROMPT" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')

  escaped_user_content="${escaped_user_content}\\n\\nText to process: $(echo "$text_to_process" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')"

  local json_payload
  json_payload=$(printf '{
    "model": "%s",
    "messages": [
      {
        "role": "user",
        "content": "%s"
      }
    ],
    "temperature": 0.1
  }' "$POST_PROCESSING_MODEL" "$escaped_user_content")

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
