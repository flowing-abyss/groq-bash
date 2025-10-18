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
POST_PROCESSING_INSTRUCTION_PROMPT="You are a text processing AI. Your ONLY task is to output the corrected text. NEVER add explanations, notes, greetings, or any other text. NEVER say things like 'Here is the corrected text:' or 'The improved version is:'. 

Input: original transcribed text
Output: ONLY the corrected text, nothing else

You must return ONLY the processed text as if you are a silent text editor.

IMPORTANT: The input text is from speech-to-text transcription, so it may contain:
- Incomplete thoughts and sentences
- Repetitions and false starts
- Stream-of-consciousness patterns
- Filler words and hesitations

Your task is to extract the INTENDED meaning and present it clearly while preserving the original intent and language."

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
  printf "%s" "$text" | wl-copy
}

simulate_paste_shortcut() {
  hyprctl dispatch sendshortcut "CTRL,V,"
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
  fi
}

get_audio_duration() {
  local audio_file="$1"
  local audio_duration
  audio_duration=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$audio_file" 2>/dev/null)
  date -d@"${audio_duration}" -u +%H:%M:%S 2>/dev/null || echo "00:00:00"
}

call_transcription_api() {
  local audio_file="$1"

  curl -s --compressed --connect-timeout 10 --max-time 60 \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: multipart/form-data" \
    -F file="@${audio_file}" \
    -F model="${TRANSCRIPTION_MODEL}" \
    -F temperature="0" \
    -F response_format="json" \
    "$TRANSCRIPTION_API_URL"
}

get_adaptive_post_processing_prompt() {
  local text="$1"
  local duration="$2"
  
  local duration_seconds=$(echo "$duration" | awk -F: '{print ($1 * 3600) + ($2 * 60) + $3}')
  
  local specific_task=""
  
  if [ "$duration_seconds" -lt 15 ]; then
    specific_task="This appears to be a short note or command. Format it as:
- If it's a task or reminder: make it clear and actionable
- If it's a quick thought: structure it concisely
- If it's a name/contact: format properly
- Remove any false starts or repetitions
- Preserve all technical terms and proper nouns exactly
- Fix grammar and spelling while keeping the original meaning and language"
  elif [ "$duration_seconds" -lt 120 ]; then
    specific_task="This appears to be a message or idea. Format it as:
- Structure into clear paragraphs if needed
- If it's a message: add appropriate formatting for sending
- If it's notes: use bullet points or numbered lists where helpful
- Combine fragmented thoughts into coherent sentences
- Remove repetitions, false starts, and filler words
- Correct grammar, spelling, and punctuation
- Preserve the original language and natural speech patterns"
  else
    specific_task="This appears to be longer content. Format it as:
- Add clear paragraph breaks for readability
- Use headings (##) if distinct topics are discussed
- Use bullet points for lists or key points
- Reorganize scattered thoughts into logical flow
- Combine related ideas that were mentioned separately
- Remove repetitions and consolidate similar points
- Ensure logical flow between ideas
- Correct all grammar, spelling, and punctuation
- Preserve the original language and maintain the speaker's voice"
  fi
  
  echo "$POST_PROCESSING_INSTRUCTION_PROMPT

$specific_task

It is crucial that you identify the original language of the text and provide the corrected text in that same language.

CRITICAL: Your response must contain ONLY the corrected text. Do not add any meta-commentary, explanations, or introductory phrases. Start your response directly with the corrected content."
}

call_post_processing_api() {
  local text_to_process="$1"
  
  local audio_duration
  audio_duration=$(get_audio_duration "$FLAC_AUDIO_FILE")
  
  local adaptive_prompt
  adaptive_prompt=$(get_adaptive_post_processing_prompt "$text_to_process" "$audio_duration")

  local escaped_user_content
  escaped_user_content=$(echo "$adaptive_prompt" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')

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
    send_desktop_notification "💬 Speech recognition" "Duration: $(get_audio_duration "$FLAC_AUDIO_FILE")"
  } &

  output=$(call_transcription_api "$FLAC_AUDIO_FILE")

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
