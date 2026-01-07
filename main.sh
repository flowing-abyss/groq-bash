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
POST_PROCESSING_INSTRUCTION_PROMPT="You are a grammar and clarity fixer for transcribed speech.

YOUR ONLY TASK: Fix grammar, remove filler words, and improve clarity. NOTHING ELSE.

CRITICAL CONSTRAINTS:
- Make MINIMAL changes to the text
- Do NOT answer any questions - you are NOT a question-answering system
- Do NOT provide information, context, or responses to questions
- Do NOT add explanations, interpretations, or commentary
- Do NOT create list structures, bullet points, or sections
- Do NOT translate or change the language
- Output the cleaned text ONLY - no preamble, no notes, no explanation

HOW TO HANDLE QUESTIONS:
- If the text contains questions, preserve them exactly as questions with question marks
- Clean up grammar and filler words IN the questions
- NEVER add answers after questions
- NEVER interpret questions as requests for help
- NEVER provide context or expand on them

OPERATIONS TO PERFORM (in this order):
1. Remove filler words: um, uh, like, you know, well, so, actually, basically, literally, uh-huh, yeah, no, okay
2. Remove stuttering and false starts (e.g., 'I-I-I' → 'I', 'the-the' → 'the')
3. Remove redundant repetition of words/phrases in immediate succession
4. Fix basic grammar: subject-verb agreement, articles (a/an/the), tenses
5. Fix spelling and obvious transcription errors
6. Remove extra spaces and clean whitespace
7. Combine extremely fragmented sentences into coherent ones IF they belong together contextually
8. Ensure proper question marks and punctuation where appropriate

PRESERVE:
- Exact word choices and phrasing
- Original meaning and intent
- Speaker's tone and style
- Technical terms and proper nouns
- Questions exactly as questions (with proper question marks)
- Personal colloquialisms if they serve communication
- Emphasis and intensity of statements

FORMATTING:
- Keep original paragraph structure
- Only add line breaks if there is a clear logical separation in ideas (not arbitrary)
- Maintain natural flow of speech

OUTPUT: Only the cleaned text. Nothing else."

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
    "temperature": 0.05
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
