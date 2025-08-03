#!/usr/bin/env bash

set -e

SCRIPT_DIR=$(dirname "$0")
TMP_DIR="/tmp"
FLAC_AUDIO_FILE="${TMP_DIR}/input.flac"

API_KEY=$(cat "${SCRIPT_DIR}/.api")
MODEL="whisper-large-v3-turbo"

START_AUDIO="$SCRIPT_DIR/start.mp3"
END_AUDIO="$SCRIPT_DIR/stop.mp3"

#───────────────────────────────────────────────────────────────────────────────

if pgrep arecord; then
    pkill arecord
    while lsof "$FLAC_AUDIO_FILE" >/dev/null 2>&1; do
        sleep 0.1
    done
    mpg123 $END_AUDIO >/dev/null 2>&1 &
    
    notify-send "💬 Speech recognition" &
    output=$(curl -s https://api.groq.com/openai/v1/audio/transcriptions \
        -H "Authorization: Bearer ${API_KEY}" \
        -H "Content-Type: multipart/form-data" \
        -F file="@${FLAC_AUDIO_FILE}" \
    -F model="${MODEL}")
    text=$(echo "$output" | jq -r '.text' | xargs)
    
    if [ -n "$text" ]; then
        echo "$text" | wl-copy
        notify-send "📋 Sent to clipboard" &
        while [ "$(wl-paste)" != "$text" ]; do
            sleep 0.1
        done
        hyprctl dispatch sendshortcut "CTRL,V,"
    fi
    
    rm "$FLAC_AUDIO_FILE"
else
    mpg123 $START_AUDIO >/dev/null 2>&1 &
    notify-send "🔴 Start recording" &
    arecord --format S16_LE --rate=16000 | ffmpeg -i - -c:a flac -compression_level 0 "$FLAC_AUDIO_FILE" >/dev/null 2>&1 &
fi
