#!/bin/bash
# RUN 4 — blind-spot closure (see BLINDSPOT_AUDIT.md). Designed for a fresh-restarted,
# idle machine, fully autonomous. Every phase: fresh seed per run, warmup pass discarded,
# interleaving where a comparison is claimed, skip counts cross-validated against
# EasyCache's own summary line.
SP="${SCRATCH:-C:/Users/ANIMAT~1/AppData/Local/Temp/claude/F--pinokio-api-comfy-git/c90d7804-f40d-4e73-8820-429b35c5559e/scratchpad}"
APP="F:/pinokio/api/comfy.git/app"
LAUNCH="F:/pinokio/api/comfy.git"
R="$SP/protocol4_results.txt"; : > "$R"
INT8_DIT="minimax_h3_fl2va_pruned_int8_convrot.safetensors"
INT8_TE="qwen3vl_32b_minimax_h3_int8_convrot.safetensors"
NVFP4_TE="qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"
SEEDF="$SP/.seed4"; echo 11000 > "$SEEDF"

log(){ echo "$@" | tee -a "$R"; }
stop(){ powershell -NoProfile -Command "Get-Process python,pythonw -ErrorAction SilentlyContinue | Where-Object { \$_.Path -like 'F:\\pinokio\\api\\comfy.git\\*' } | Stop-Process -Force" >/dev/null 2>&1; sleep 6; }
trap 'stop' EXIT INT TERM
next_seed(){ s=$(cat "$SEEDF"); s=$((s+1)); echo $s > "$SEEDF"; echo $s; }

# Precondition: refuse to bench a busy GPU.
UTIL=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | tr -d ' \r')
if [ "${UTIL:-100}" -gt 10 ]; then log "!! GPU at ${UTIL}% — machine not idle, aborting run4"; exit 1; fi

start_server(){
  local slog="$1"; shift
  stop
  ( cd "$APP" && TOKENIZERS_PARALLELISM=false PYTHONIOENCODING=utf-8 \
      ./env/python.exe main.py --port 8189 --disable-auto-launch "$@" > "$slog" 2>&1 & )
  local w=0; until grep -q "To see the GUI go to" "$slog" 2>/dev/null; do sleep 5; w=$((w+5)); [ $w -gt 900 ] && return 1; done
  return 0
}

# OUT W H L SEED EC START END TE
mkwf(){
  OUT="$1" W="$2" H="$3" L="$4" SEED="$5" EC="$6" ST="$7" EN="$8" TEV="${9:-$INT8_TE}" DIT="$INT8_DIT" SRC="$LAUNCH/bench/bench_480p_5s.api.json" node -e '
const fs=require("fs"), e=process.env;
const w=JSON.parse(fs.readFileSync(e.SRC,"utf8"));
w["104"].inputs.width=+e.W; w["104"].inputs.height=+e.H; w["104"].inputs.length=+e.L;
w["6"].inputs.unet_name=e.DIT; w["13"].inputs.clip_name=e.TEV;
w["15"].inputs.noise_seed=+e.SEED; w["92"].inputs.filename_prefix="video/p4";
let src=["6",0];
if(e.EC){ w["200"]={class_type:"EasyCache",inputs:{model:src,reuse_threshold:parseFloat(e.EC),start_percent:parseFloat(e.ST),end_percent:parseFloat(e.EN),verbose:true}}; src=["200",0]; }
w["16"].inputs.model=src; w["9"].inputs.model=src;
fs.writeFileSync(e.OUT,JSON.stringify(w,null,2));'
}

# label W H L seed EC start end TE outdir serverflags...
trial(){
  local label="$1" W="$2" H="$3" L="$4" SEED="$5" EC="$6" ST="$7" EN="$8" TEV="$9" OUTD="${10}"; shift 10
  local slog="$SP/s4_${label}.log"
  start_server "$slog" "$@" || { log "  $label: SERVER FAIL"; return; }
  mkwf "$SP/w4_warm.json" "$W" "$H" "$L" "$(next_seed)" "$EC" "$ST" "$EN" "$TEV"
  ( cd "$LAUNCH" && node comfy-api.js run "$SP/w4_warm.json" --url http://127.0.0.1:8189 --out "$SP/p4_warm" --timeout 9000 >/dev/null 2>&1 )
  mkwf "$SP/w4_meas.json" "$W" "$H" "$L" "$SEED" "$EC" "$ST" "$EN" "$TEV"
  local st=$(date +%s)
  ( cd "$LAUNCH" && node comfy-api.js run "$SP/w4_meas.json" --url http://127.0.0.1:8189 --out "$OUTD" --timeout 9000 > "$SP/r4_${label}.log" 2>&1 )
  local rc=$?; local en=$(date +%s)
  local sit=$(tr '\r' '\n' < "$slog" | grep -oE "20/20 \[[0-9:]+<[0-9:]+, *[0-9.]+s/it\]" | tail -1 | grep -oE "[0-9.]+s/it")
  local skip=$(grep -oE "EasyCache - skipped [0-9]+/[0-9]+ steps" "$slog" | tail -1 | grep -oE "[0-9]+/[0-9]+")
  if [ $rc -ne 0 ]; then log "  $label: FAILED -> $(tail -2 "$SP/r4_${label}.log" | tr '\n' ' ' | cut -c1-160)";
  else log "  $label: s/it=${sit:-?} total=$((en-st))s ${skip:+skips=$skip}"; fi
}

log "===== RUN 4 (blind-spot closure) $(date) ====="
log ""
log "P1 — CLEAN NATIVE STOCK PAIR (highest value: real Sage gain at production res)"
trial "p1_nat_stock_r1" 1344 768 124 20001 "" 0 0 "$INT8_TE" "$SP/p4_out"
trial "p1_nat_sage_r1"  1344 768 124 20002 "" 0 0 "$INT8_TE" "$SP/p4_out" --use-sage-attention
trial "p1_nat_stock_r2" 1344 768 124 20003 "" 0 0 "$INT8_TE" "$SP/p4_out"
trial "p1_nat_sage_r2"  1344 768 124 20004 "" 0 0 "$INT8_TE" "$SP/p4_out" --use-sage-attention
log ""
log "P2 — TE A/B CLEAN (README claims int8>nvfp4 from contaminated single runs)"
trial "p2_int8te_r1"  864 480 124 21001 "" 0 0 "$INT8_TE"  "$SP/p4_out" --use-sage-attention
trial "p2_nvfp4te_r1" 864 480 124 21002 "" 0 0 "$NVFP4_TE" "$SP/p4_out" --use-sage-attention
trial "p2_int8te_r2"  864 480 124 21003 "" 0 0 "$INT8_TE"  "$SP/p4_out" --use-sage-attention
trial "p2_nvfp4te_r2" 864 480 124 21004 "" 0 0 "$NVFP4_TE" "$SP/p4_out" --use-sage-attention
log ""
log "P3 — VRAM FLAGS CLEAN (old A/B was contaminated; async-offload never ran at all)"
trial "p3_stock_r1"    864 480 124 22001 "" 0 0 "$INT8_TE" "$SP/p4_out" --use-sage-attention
trial "p3_noasync_r1"  864 480 124 22002 "" 0 0 "$INT8_TE" "$SP/p4_out" --use-sage-attention --disable-async-offload
trial "p3_stock_r2"    864 480 124 22003 "" 0 0 "$INT8_TE" "$SP/p4_out" --use-sage-attention
trial "p3_noasync_r2"  864 480 124 22004 "" 0 0 "$INT8_TE" "$SP/p4_out" --use-sage-attention --disable-async-offload
trial "p3_highvram"    864 480 124 22005 "" 0 0 "$INT8_TE" "$SP/p4_out" --use-sage-attention --highvram
trial "p3_nodynamic"   864 480 124 22006 "" 0 0 "$INT8_TE" "$SP/p4_out" --use-sage-attention --disable-dynamic-vram
log ""
log "P4 — 480p/10s CLEAN (old 17.2 s/it stock was contaminated) + EC skip pattern at 243f"
trial "p4_10s_stock" 864 480 243 23001 ""    0    0    "$INT8_TE" "$SP/p4_out"
trial "p4_10s_sage"  864 480 243 23002 ""    0    0    "$INT8_TE" "$SP/p4_out" --use-sage-attention
trial "p4_10s_ec02"  864 480 243 23003 "0.2" 0.15 0.95 "$INT8_TE" "$SP/p4_out" --use-sage-attention
log ""
log "P5 — EC AT NATIVE RES (threshold portability across resolution, same box)"
trial "p5_nat_ec02" 1344 768 124 24001 "0.2" 0.15 0.95 "$INT8_TE" "$SP/p4q_natec" --use-sage-attention
log ""
log "P6 — SEED ROBUSTNESS (cliff rests on one seed) + TAIL RULE ON THIS BOX"
for SD in 111111 222222; do
  trial "p6_${SD}_nocache" 864 480 124 $SD ""    0    0    "$INT8_TE" "$SP/p4q_${SD}_none" --use-sage-attention
  trial "p6_${SD}_ec02"    864 480 124 $SD "0.2" 0.15 0.95 "$INT8_TE" "$SP/p4q_${SD}_ec02" --use-sage-attention
  trial "p6_${SD}_thr06"   864 480 124 $SD "0.6" 0.15 0.95 "$INT8_TE" "$SP/p4q_${SD}_thr06" --use-sage-attention
done
trial "p6_tail_no"  864 480 124 909090 "0.2" 0.15 0.95 "$INT8_TE" "$SP/p4q_tail_no"  --use-sage-attention
trial "p6_tail_yes" 864 480 124 909090 "0.2" 0.15 1.00 "$INT8_TE" "$SP/p4q_tail_yes" --use-sage-attention
log ""
log "P7 — comfy-kitchen TRITON BACKEND (reports available:True disabled:True every boot)"
trial "p7_triton" 864 480 124 25001 "" 0 0 "$INT8_TE" "$SP/p4_out" --use-sage-attention --enable-triton-backend
log ""
log "P8 — THRESHOLD SATURATION (0.6 and 0.8 gave identical sequences; find the ceiling)"
trial "p8_thr15" 864 480 124 26001 "1.5" 0.15 0.95 "$INT8_TE" "$SP/p4_out" --use-sage-attention
log ""
log "===== RUN 4 COMPLETE $(date) ====="
stop
