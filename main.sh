#!/usr/bin/env bash

set -e

SCRIPT_DIR=$(dirname "$0")
AUDIO_FILE="/tmp/input.wav"
API_KEY=$(cat "${SCRIPT_DIR}/.api")
MODEL="whisper-large-v3-turbo"

START_AUDIO="$SCRIPT_DIR/start.mp3"
END_AUDIO="$SCRIPT_DIR/stop.mp3"

#───────────────────────────────────────────────────────────────────────────────

if pgrep arecord; then
    pkill arecord
    sleep 0.2s
    mpg123 $END_AUDIO >/dev/null 2>&1 &

    notify-send "💬 Speech recognition"
    output=$(curl -s https://api.groq.com/openai/v1/audio/transcriptions \
        -H "Authorization: Bearer ${API_KEY}" \
        -H "Content-Type: multipart/form-data" \
        -F file="@${AUDIO_FILE}" \
        -F model="${MODEL}")
    text=$(echo "$output" | jq -r '.text')

    wl-copy $text
    sleep 0.1s
    hyprctl dispatch sendshortcut "CTRL,V,"
    notify-send "📋 Sent to clipboard"

    rm "$AUDIO_FILE"
else
    mpg123 $START_AUDIO >/dev/null 2>&1 &
    arecord --format S16_LE --rate=16000 "$AUDIO_FILE" >/dev/null 2>&1 &
    notify-send "🔴 Start recording"
fi
