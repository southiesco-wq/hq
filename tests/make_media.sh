#!/bin/bash
# Builds a set of test videos covering common sound formats.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p media && cd media
V="-f lavfi -i testsrc2=size=640x360:rate=30:duration=8"
VENC="-c:v libx264 -pix_fmt yuv420p -preset veryfast"

# Real speech from macOS's built-in voice, plus background noise.
say -o speech.aiff "Hello, this is a test of the noise remover. We are cooking with confidence today, and the kitchen fan is very loud."
ffmpeg -loglevel error -y -i speech.aiff -af "apad=whole_dur=8,adelay=1000|1000" -ar 48000 -ac 1 speech.wav
ffmpeg -loglevel error -y -i speech.wav -f lavfi -i "anoisesrc=color=pink:amplitude=0.08:duration=8:sample_rate=48000" \
  -filter_complex "[0][1]amix=inputs=2:normalize=0,pan=stereo|c0=c0|c1=c0" -ar 48000 noisy_stereo.wav

# 1. Stereo AAC, speech + noise on both sides (like a phone video)
ffmpeg -loglevel error -y $V -i noisy_stereo.wav $VENC -c:a aac -b:a 192k -shortest stereo_aac.mov
# 2. Sound only on the left (a lav mic on one channel)
ffmpeg -loglevel error -y $V -i speech.wav -filter_complex "[1]pan=stereo|c0=c0|c1=0*c0[a]" -map 0 -map "[a]" $VENC -c:a aac -shortest left_only.mov
# 3. 4-channel 24-bit PCM (field recorders, some cameras)
ffmpeg -loglevel error -y $V -i speech.wav -filter_complex "[1]pan=4.0|c0=c0|c1=c0|c2=0.5*c0|c3=0.5*c0[a]" -map 0 -map "[a]" $VENC -c:a pcm_s24le -shortest pcm24_4ch.mov
# 4. 5.1 AAC in MP4
ffmpeg -loglevel error -y $V -i speech.wav -filter_complex "[1]pan=5.1|c0=c0|c1=c0|c2=c0|c3=0*c0|c4=0.5*c0|c5=0.5*c0[a]" -map 0 -map "[a]" $VENC -c:a aac -shortest aac_51.mp4
# 5. Mono AAC at 44.1 kHz
ffmpeg -loglevel error -y $V -i speech.wav $VENC -c:a aac -ac 1 -ar 44100 -shortest mono_441.mov
# 6. Two sound tracks: 4ch PCM first, stereo AAC second
ffmpeg -loglevel error -y $V -i speech.wav -filter_complex "[1]pan=4.0|c0=c0|c1=c0|c2=c0|c3=c0[q];[1]pan=stereo|c0=c0|c1=c0[s]" \
  -map 0 -map "[q]" -map "[s]" $VENC -c:a:0 pcm_s16le -c:a:1 aac -shortest two_tracks.mov
# 7. Apple Lossless with HEVC video
ffmpeg -loglevel error -y $V -i noisy_stereo.wav -c:v libx265 -tag:v hvc1 -pix_fmt yuv420p -preset ultrafast -c:a alac -shortest hevc_alac.mov
# 8. Out-of-phase stereo (sides cancel when mixed)
ffmpeg -loglevel error -y $V -i speech.wav -filter_complex "[1]pan=stereo|c0=c0|c1=-1*c0[a]" -map 0 -map "[a]" $VENC -c:a aac -shortest phase.mov
# 9. MP3 sound in MOV
ffmpeg -loglevel error -y $V -i noisy_stereo.wav $VENC -c:a libmp3lame -shortest mp3.mov || true
# 10. Opus in MP4 (may not be readable by every macOS)
ffmpeg -loglevel error -y $V -i noisy_stereo.wav $VENC -c:a libopus -shortest opus.mp4 || true
ls -la
