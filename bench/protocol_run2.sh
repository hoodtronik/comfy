#!/bin/bash
# Phases 4-7. $1 = DiT filename to use as the base (decided by the quality A/B).
SP="C:/Users/ANIMAT~1/AppData/Local/Temp/claude/F--pinokio-api-comfy-git/c90d7804-f40d-4e73-8820-429b35c5559e/scratchpad"
APP="F:/pinokio/api/comfy.git/app"
LAUNCH="F:/pinokio/api/comfy.git"
R="$SP/protocol2_results.txt"; : > "$R"
DIT="${1:-minimax_h3_fl2va_pruned_int8_convrot.safetensors}"
TE="qwen3vl_32b_minimax_h3_int8_convrot.safetensors"
SEEDF="$SP/.seed2"; echo 7000 > "$SEEDF"

log(){ echo "$@" | tee -a "$R"; }
stop(){ powershell -NoProfile -Command "Get-Process python,pythonw -ErrorAction SilentlyContinue | Where-Object { \$_.Path -like 'F:\\pinokio\\api\\comfy.git\\*' } | Stop-Process -Force" >/dev/null 2>&1; sleep 6; }
trap 'stop' EXIT INT TERM
next_seed(){ s=$(cat "$SEEDF"); s=$((s+1)); echo $s > "$SEEDF"; echo $s; }

start_server(){
  local slog="$1"; shift
  stop
  ( cd "$APP" && TOKENIZERS_PARALLELISM=false PYTHONIOENCODING=utf-8 \
      ./env/python.exe main.py --port 8189 --disable-auto-launch "$@" > "$slog" 2>&1 & )
  local w=0; until grep -q "To see the GUI go to" "$slog" 2>/dev/null; do sleep 5; w=$((w+5)); [ $w -gt 600 ] && return 1; done
  return 0
}

# $1 out $2 w $3 h $4 len $5 seed $6 easycache_threshold(optional, "" = none)
mkwf(){
  local OUT="$1" W="$2" H="$3" L="$4" SEED="$5" EC="$6"
  OUT="$OUT" W="$W" H="$H" L="$L" SEED="$SEED" EC="$EC" DIT="$DIT" TE="$TE" SRC="$SP/bench_480p_5s.api.json" node -e '
const fs=require("fs");
const e=process.env;
const w=JSON.parse(fs.readFileSync(e.SRC,"utf8"));
w["104"].inputs.width=+e.W; w["104"].inputs.height=+e.H; w["104"].inputs.length=+e.L;
w["6"].inputs.unet_name=e.DIT; w["13"].inputs.clip_name=e.TE;
w["15"].inputs.noise_seed=+e.SEED; w["92"].inputs.filename_prefix="video/p2";
if(e.EC){
  // EasyCache sits between the model loader and everything that consumes MODEL
  w["200"]={class_type:"EasyCache",inputs:{model:["6",0],reuse_threshold:parseFloat(e.EC),start_percent:0.15,end_percent:0.95,verbose:true}};
  w["16"].inputs.model=["200",0];
  w["9"].inputs.model=["200",0];
}
fs.writeFileSync(e.OUT,JSON.stringify(w,null,2));'
}

# $1 label $2 w $3 h $4 len $5 easycache $6.. flags
trial(){
  local label="$1" W="$2" H="$3" L="$4" EC="$5"; shift 5
  local slog="$SP/s2_${label}.log"
  start_server "$slog" "$@" || { log "  $label: SERVER FAIL"; return; }
  mkwf "$SP/w2_warm.json" "$W" "$H" "$L" "$(next_seed)" "$EC"
  ( cd "$LAUNCH" && node comfy-api.js run "$SP/w2_warm.json" --url http://127.0.0.1:8189 --out "$SP/p2_out" --timeout 7200 >/dev/null 2>&1 )
  mkwf "$SP/w2_meas.json" "$W" "$H" "$L" "$(next_seed)" "$EC"
  local st=$(date +%s)
  ( cd "$LAUNCH" && node comfy-api.js run "$SP/w2_meas.json" --url http://127.0.0.1:8189 --out "$SP/p2_out" --timeout 7200 > "$SP/r2_${label}.log" 2>&1 )
  local rc=$?; local en=$(date +%s)
  local sit=$(tr '\r' '\n' < "$slog" | grep -oE "20/20 \[[0-9:]+<[0-9:]+, *[0-9.]+s/it\]" | tail -1 | grep -oE "[0-9.]+s/it")
  if [ $rc -ne 0 ]; then log "  $label: FAILED -> $(tail -2 "$SP/r2_${label}.log" | tr '\n' ' ' | cut -c1-160)";
  else log "  $label: s/it=${sit:-?}  total=$((en-st))s"; fi
}

log "===== PROTOCOL RUN 2 $(date) — base DiT: $DIT ====="
log ""
log "PHASE 4 — EasyCache (sage on, 864x480/124f). Quality must be checked separately."
trial "p4_nocache"   864 480 124 ""     --use-sage-attention
trial "p4_ec_0.2"    864 480 124 "0.2"  --use-sage-attention
trial "p4_ec_0.4"    864 480 124 "0.4"  --use-sage-attention
log ""
log "PHASE 5 — --fast flags (sage on, no cache)"
trial "p5_fp16acc"  864 480 124 "" --use-sage-attention --fast fp16_accumulation
trial "p5_fastall"  864 480 124 "" --use-sage-attention --fast
log ""
log "PHASE 6 — native 1344x768 with sage (replaces the projections)"
trial "p6_native_5s"  1344 768 124 "" --use-sage-attention
trial "p6_native_10s" 1344 768 243 "" --use-sage-attention
log ""
log "===== RUN 2 COMPLETE $(date) ====="
stop
