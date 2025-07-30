# groq-bash (speech-to-text)

This script (`main.sh`) provides a simple way to record audio and transcribe it using the Groq API.

It functions as a toggle:
*   **First call:** Records audio.
*   **Second call:** Transcribes the recorded audio using Groq.

## Required Programs

Ensure these programs are installed on your system:
*   `arecord` (from `alsa-utils`)
*   `mpg123`
*   `curl`
*   `jq`
*   `notify-send` (from `libnotify`)
*   `wl-copy` (from `wl-clipboard`)
*   `hyprctl` (Hyprland)
*   `ffmpeg`

## Installation

To get a copy of this project up and running on your local machine, follow these steps:

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/flowing-abyss/groq-bash
    cd groq-bash
    ```
2.  **Set up API Key:** Place your Groq API key in a file named `.api` in the project directory.
    Example `.api` file content:
    ```
    gsk_P4r7yWYE...
    ```
3.  **Make the script executable:**
    ```bash
    chmod +x main.sh
    ```

## Usage

The script works as follows:
1.  **Start Recording:** Run `./main.sh`. The script will play a "start" sound and begin recording audio to `/tmp/input.wav`. A notification "🔴 Start recording" will be displayed.
2.  **Stop Recording & Transcribe:** Run `./main.sh` again while recording is active. The script will stop `arecord`, play a "stop" sound, convert the WAV to FLAC, send it to the Groq API for transcription, copy the text to clipboard, and send a `CTRL+V` shortcut. Notifications for "Processing speech..." and "📋 Sent to clipboard" will be displayed. Temporary audio files will be cleaned up.