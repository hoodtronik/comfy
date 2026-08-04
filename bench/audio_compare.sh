#!/bin/bash
# Audio-track comparison across H3 variants (BLINDSPOT_AUDIT Tier 4 #1).
# Every quality verdict so far looked at video frames only; H3's audio is generated
# jointly, so cache/quant artifacts could land in the audio invisibly.
# Usage: audio_compare.sh <out.txt> <label:file.mp4> [label:file.mp4 ...]
# Emits per-clip loudness/peak/flatness stats and a spectrogram PNG next to each clip.
# This is triage for human ears, not a verdict: flag deltas, then the user listens.
FF="F:/pinokio/bin/ffmpeg-env/Library/bin/ffmpeg.exe"
OUT="$1"; shift
: > "$OUT"
for pair in "$@"; do
  label="${pair%%:*}"; f="${pair#*:}"
  [ -f "$f" ] || { echo "$label: MISSING $f" >> "$OUT"; continue; }
  echo "=== $label ===" >> "$OUT"
  "$FF" -v info -i "$f" -map 0:a -af astats=metadata=1,ametadata=print -f null - 2>&1 \
    | grep -E "RMS level dB|Peak level dB|Flat factor|Zero crossings rate|DC offset" \
    | sort -u | head -10 >> "$OUT"
  "$FF" -v error -y -i "$f" -lavfi showspectrumpic=s=1024x400:legend=1 "${f%.mp4}_spectrum.png" 2>/dev/null \
    && echo "  spectrum: ${f%.mp4}_spectrum.png" >> "$OUT"
done
echo "AUDIO COMPARE DONE" >> "$OUT"
