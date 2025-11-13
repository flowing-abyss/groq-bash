# Agent Guidelines for groq-bash

## Project Overview
Bash script for speech-to-text transcription using Groq API. Toggle-based audio recording with automatic transcription.

## Commands
- **Run script**: `./main.sh` (toggle: start recording / stop & transcribe)
- **No tests**: This is a standalone Bash script with no test suite
- **No build**: Script runs directly, no compilation needed

## Code Style
- **Language**: Pure Bash (#!/usr/bin/env bash)
- **Safety**: Always use `set -e` at script start
- **Indentation**: 2 spaces (see .editorconfig)
- **Variables**: UPPERCASE for constants/config, lowercase for local/temporary
- **Quoting**: Always quote variables ("$variable") to prevent word splitting
- **Functions**: Use snake_case naming, declare local variables with `local`
- **Error handling**: Use `>/dev/null 2>&1` to suppress command output; check exit codes with conditionals
- **Dependencies**: Check external tools (arecord, ffmpeg, curl, jq, notify-send, wl-copy, hyprctl, mpg123)
- **Temp files**: Use /tmp for temporary storage, clean up on exit
- **API calls**: Use curl with timeouts (--connect-timeout, --max-time)
- **JSON**: Use jq for parsing JSON responses

## Key Patterns
- PID file tracking for process management
- Background notifications using `&` for async execution
- Audio processing pipeline: arecord → ffmpeg → FLAC
- API workflow: transcription → optional post-processing → clipboard
