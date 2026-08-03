#!/bin/bash
# Phase 7-9 (revised after the 4090 retracted the streaming-floor inversion):
#   7. TorchCompile (owed)
#   8. Same-seed EasyCache quality — now tests a SYMMETRIC prediction. Our 0.4 configs
#      are near-identical (10 skips, max run 3, late-bunched), so under the run-length
#      hypothesis mine should smear like theirs. If mine is clean, run-length is not the
#      variable and it's content/seed.
#   9. Distribution isolation: matched-ish skip TOTAL, different RUN LENGTH, via the
#      caching window. Narrow window forces skips to bunch. This is the one open
#      mechanism question left.
SP="C:/Users/ANIMAT~1/AppData/Local/Temp/claude/F--pinokio-api-comfy-git/c90d7804-f40d-4e73-8820-429b35c5559e/scratchpad"
APP="F:/pinokio/api/comfy.git/app"
LAUNCH="F:/pinokio/api/comfy.git"
R="$SP/protocol3_results.txt"; : > "$R"
DIT="minimax_h3_fl2va_pruned_int8_convrot.safetensors"
TE="qwen3vl_32b_minimax_h3_int8_convrot.safetensors"
QSEED=909090

log(){ echo "$@" | tee -a "$R"; }
stop(){ powershell -NoProfile -Command "Get-Process python,pythonw -ErrorAction SilentlyContinue | Where-Object { \$_.Path -like 'F:\\pinokio\\api\\comfy.git\\*' } | Stop-Process -Force" >/dev/null 2>&1; sleep 6; }
trap 'stop' EXIT INT TERM

start_server(){
  local slog="$1"; shift
  stop
  ( cd "$APP" && TOKENIZERS_PARALLELISM=false PYTHONIOENCODING=utf-8 \
      ./env/python.exe main.py --port 8189 --disable-auto-launch "$@" > "$slog" 2>&1 & )
  local w=0; until grep -q "To see the GUI go to" "$slog" 2>/dev/null; do sleep 5; w=$((w+5)); [ $w -gt 900 ] && return 1; done
  return 0
}

# OUT W H L SEED EC START END COMPILE
mkwf(){
  OUT="$1" W="$2" H="$3" L="$4" SEED="$5" EC="$6" ST="$7" EN="$8" COMPILE="$9" DIT="$DIT" TE="$TE" SRC="$SP/bench_480p_5s.api.json" node -e '
const fs=require("fs"), e=process.env;
const w=JSON.parse(fs.readFileSync(e.SRC,"utf8"));
w["104"].inputs.width=+e.W; w["104"].inputs.height=+e.H; w["104"].inputs.length=+e.L;
w["6"].inputs.unet_name=e.DIT; w["13"].inputs.clip_name=e.TE;
w["15"].inputs.noise_seed=+e.SEED; w["92"].inputs.filename_prefix="video/p3";
let src=["6",0];
if(e.COMPILE){ w["201"]={class_type:"TorchCompileModel",inputs:{model:src,backend:e.COMPILE}}; src=["201",0]; }
if(e.EC){ w["200"]={class_type:"EasyCache",inputs:{model:src,reuse_threshold:parseFloat(e.EC),start_percent:parseFloat(e.ST),end_percent:parseFloat(e.EN),verbose:true}}; src=["200",0]; }
w["16"].inputs.model=src; w["9"].inputs.model=src;
fs.writeFileSync(e.OUT,JSON.stringify(w,null,2));'
}

# label W H L seed EC start end compile outdir flags...
trial(){
  local label="$1" W="$2" H="$3" L="$4" SEED="$5" EC="$6" ST="$7" EN="$8" CMP="$9" OUTD="${10}"; shift 10
  local slog="$SP/s3_${label}.log"
  start_server "$slog" "$@" || { log "  $label: SERVER FAIL"; return; }
  mkwf "$SP/w3_warm.json" "$W" "$H" "$L" "$((SEED+1))" "$EC" "$ST" "$EN" "$CMP"
  ( cd "$LAUNCH" && node comfy-api.js run "$SP/w3_warm.json" --url http://127.0.0.1:8189 --out "$SP/p3_warm" --timeout 9000 > "$SP/w3warm_${label}.log" 2>&1 )
  mkwf "$SP/w3_meas.json" "$W" "$H" "$L" "$SEED" "$EC" "$ST" "$EN" "$CMP"
  local st=$(date +%s)
  ( cd "$LAUNCH" && node comfy-api.js run "$SP/w3_meas.json" --url http://127.0.0.1:8189 --out "$OUTD" --timeout 9000 > "$SP/r3_${label}.log" 2>&1 )
  local rc=$?; local en=$(date +%s)
  local sit=$(tr '\r' '\n' < "$slog" | grep -oE "20/20 \[[0-9:]+<[0-9:]+, *[0-9.]+s/it\]" | tail -1 | grep -oE "[0-9.]+s/it")
  # authoritative skip count from EasyCache's own summary, NOT a grep of verbose lines
  local skip=$(grep -oE "EasyCache - skipped [0-9]+/[0-9]+ steps" "$slog" | tail -1 | grep -oE "[0-9]+/[0-9]+")
  if [ $rc -ne 0 ]; then log "  $label: FAILED -> $(tail -2 "$SP/r3_${label}.log" | tr '\n' ' ' | cut -c1-170)";
  else log "  $label: s/it=${sit:-?} total=$((en-st))s ${skip:+skips=$skip}"; fi
}

log "===== PROTOCOL RUN 3 $(date) ====="
log ""
log "PHASE 7 — TorchCompile inductor (triton 3.5.1), 864x480/124f, sage on"
trial "p7_compile" 864 480 124 5001 "" 0.15 0.95 "inductor" "$SP/p3_out" --use-sage-attention
log ""
log "PHASE 8 — same-seed EasyCache quality (seed $QSEED), sage on"
trial "p8_nocache" 864 480 124 $QSEED ""    0.15 0.95 "" "$SP/p3q_nocache" --use-sage-attention
trial "p8_ec02"    864 480 124 $QSEED "0.2" 0.15 0.95 "" "$SP/p3q_ec02"    --use-sage-attention
trial "p8_ec04"    864 480 124 $QSEED "0.4" 0.15 0.95 "" "$SP/p3q_ec04"    --use-sage-attention
log ""
log "PHASE 9 — distribution isolation: same threshold, narrowed window to force bunching"
trial "p9_spread_st15" 864 480 124 $QSEED "0.2" 0.15 0.95 "" "$SP/p3d_spread" --use-sage-attention
trial "p9_bunch_st50"  864 480 124 $QSEED "0.2" 0.50 0.95 "" "$SP/p3d_b50"    --use-sage-attention
trial "p9_bunch_st65"  864 480 124 $QSEED "0.3" 0.65 1.00 "" "$SP/p3d_b65"    --use-sage-attention
log ""
log "===== RUN 3 COMPLETE $(date) ====="
stop
