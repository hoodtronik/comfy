#!/bin/bash
# Overnight protocol run. Discipline enforced per PROTOCOLS.md §2:
#   fresh seed every run, warmup pass discarded, interleaved configs, s/it is the metric,
#   detached servers explicitly reaped (killing the script does not reap its children).
SP="C:/Users/ANIMAT~1/AppData/Local/Temp/claude/F--pinokio-api-comfy-git/c90d7804-f40d-4e73-8820-429b35c5559e/scratchpad"
APP="F:/pinokio/api/comfy.git/app"
LAUNCH="F:/pinokio/api/comfy.git"
R="$SP/protocol_results.txt"
SEEDF="$SP/.seed"; [ -f "$SEEDF" ] || echo 5000 > "$SEEDF"

log(){ echo "$@" | tee -a "$R"; }

stop_server(){
  powershell -NoProfile -Command "Get-Process python,pythonw -ErrorAction SilentlyContinue | Where-Object { \$_.Path -like 'F:\\pinokio\\api\\comfy.git\\*' } | Stop-Process -Force" >/dev/null 2>&1
  sleep 6
}
trap 'stop_server' EXIT INT TERM

next_seed(){ s=$(cat "$SEEDF"); s=$((s+1)); echo $s > "$SEEDF"; echo $s; }

# build a workflow variant: $1=out $2=w $3=h $4=len $5=unet $6=clip $7=seed
mkwf(){
  node -e "
const fs=require('fs');
const w=JSON.parse(fs.readFileSync('$SP/bench_480p_5s.api.json','utf8'));
w['104'].inputs.width=$2; w['104'].inputs.height=$3; w['104'].inputs.length=$4;
w['6'].inputs.unet_name='$5'; w['13'].inputs.clip_name='$6';
w['15'].inputs.noise_seed=$7; w['92'].inputs.filename_prefix='video/proto';
fs.writeFileSync('$1',JSON.stringify(w,null,2));"
}

# start server, wait for bind. $1=logfile  $2..=flags
start_server(){
  local log="$1"; shift
  stop_server
  ( cd "$APP" && TOKENIZERS_PARALLELISM=false PYTHONIOENCODING=utf-8 \
      ./env/python.exe main.py --port 8189 --disable-auto-launch "$@" > "$log" 2>&1 & )
  local w=0
  until grep -q "To see the GUI go to" "$log" 2>/dev/null; do
    sleep 5; w=$((w+5))
    if [ $w -gt 600 ]; then log "  !! server failed to bind (see $(basename $log))"; return 1; fi
  done
  return 0
}

# one measured trial: $1=label $2=wf $3=serverlog  (assumes server already up + warmed)
measure(){
  local label="$1" wf="$2" slog="$3"
  local st=$(date +%s)
  ( cd "$LAUNCH" && node comfy-api.js run "$wf" --url http://127.0.0.1:8189 --out "$SP/proto_out" --timeout 7200 > "$SP/run_${label}.log" 2>&1 )
  local rc=$?; local en=$(date +%s)
  local sit=$(tr '\r' '\n' < "$slog" | grep -oE "20/20 \[[0-9:]+<[0-9:]+, *[0-9.]+s/it\]" | tail -1 | grep -oE "[0-9.]+s/it")
  if [ $rc -ne 0 ]; then
    log "  $label: FAILED -> $(tail -2 "$SP/run_${label}.log" | tr '\n' ' ' | cut -c1-150)"
  else
    log "  $label: s/it=${sit:-?}  total=$((en-st))s"
  fi
}

# full trial with warmup: $1=label $2=w $3=h $4=len $5=unet $6=clip $7=serverflags...
trial(){
  local label="$1" W="$2" H="$3" L="$4" UNET="$5" CLIP="$6"; shift 6
  local slog="$SP/srv_${label}.log"
  start_server "$slog" "$@" || return
  mkwf "$SP/wf_warm.json" "$W" "$H" "$L" "$UNET" "$CLIP" "$(next_seed)"
  ( cd "$LAUNCH" && node comfy-api.js run "$SP/wf_warm.json" --url http://127.0.0.1:8189 --out "$SP/proto_out" --timeout 7200 >/dev/null 2>&1 )
  mkwf "$SP/wf_meas.json" "$W" "$H" "$L" "$UNET" "$CLIP" "$(next_seed)"
  # sample GPU state mid-run
  ( sleep 60; nvidia-smi --query-gpu=clocks.sm,temperature.gpu,power.draw,utilization.gpu --format=csv,noheader > "$SP/gpu_${label}.txt" 2>/dev/null ) &
  measure "$label" "$SP/wf_meas.json" "$slog"
  [ -f "$SP/gpu_${label}.txt" ] && log "      gpu@60s: $(cat "$SP/gpu_${label}.txt")"
}

INT8_DIT="minimax_h3_fl2va_pruned_int8_convrot.safetensors"
FP8_DIT="minimax_h3_fl2va_pruned_fp8_scaled.safetensors"
INT4_DIT="MiniMax_H3_FL2VA_pruned_int4_convrot.safetensors"
INT8_TE="qwen3vl_32b_minimax_h3_int8_convrot.safetensors"
INT4_TE="qwen3vl_32b_minimax_h3_int4_convrot.safetensors"

log "===== PROTOCOL RUN $(date) ====="
log ""
log "PHASE 1 — SageAttention A/B, interleaved x2, 864x480/124f, int8 DiT+TE"
trial "p1_stock_r1" 864 480 124 "$INT8_DIT" "$INT8_TE"
trial "p1_sage_r1"  864 480 124 "$INT8_DIT" "$INT8_TE" --use-sage-attention
trial "p1_stock_r2" 864 480 124 "$INT8_DIT" "$INT8_TE"
trial "p1_sage_r2"  864 480 124 "$INT8_DIT" "$INT8_TE" --use-sage-attention
log ""
log "PHASE 2 — DiT quantization, sage on, 864x480/124f"
trial "p2_int8_r1" 864 480 124 "$INT8_DIT" "$INT8_TE" --use-sage-attention
trial "p2_fp8_r1"  864 480 124 "$FP8_DIT"  "$INT8_TE" --use-sage-attention
trial "p2_int8_r2" 864 480 124 "$INT8_DIT" "$INT8_TE" --use-sage-attention
trial "p2_fp8_r2"  864 480 124 "$FP8_DIT"  "$INT8_TE" --use-sage-attention
log ""
log "PHASE 3 — INT4 (third-party: does it even load?)"
trial "p3_int4dit"  864 480 124 "$INT4_DIT" "$INT8_TE" --use-sage-attention
trial "p3_int4both" 864 480 124 "$INT4_DIT" "$INT4_TE" --use-sage-attention
log ""
log "===== PHASES 1-3 COMPLETE $(date) ====="
stop_server
