#!/bin/bash
# Interleaved stock-vs-sage A/B so both configs see the same thermal state.
# Two rounds, alternating, fresh seed every run (ComfyUI caches identical workflows).
SP="C:/Users/ANIMAT~1/AppData/Local/Temp/claude/F--pinokio-api-comfy-git/c90d7804-f40d-4e73-8820-429b35c5559e/scratchpad"
APP="F:/pinokio/api/comfy.git/app"
R="$SP/sage_ab_results.txt"; : > "$R"

stop() { powershell -NoProfile -Command "Get-Process python -ErrorAction SilentlyContinue | Where-Object { \$_.Path -like 'F:\\pinokio\\api\\comfy.git\\*' } | Stop-Process -Force" >/dev/null 2>&1; sleep 6; }

seed=100
run() {
  local label="$1" flags="$2"
  stop
  local log="$SP/ab_${label}.log"
  ( cd "$APP" && TOKENIZERS_PARALLELISM=false PYTHONIOENCODING=utf-8 ./env/python.exe main.py --port 8189 --disable-auto-launch $flags > "$log" 2>&1 & )
  local w=0; until grep -q "To see the GUI go to" "$log" 2>/dev/null; do sleep 5; w=$((w+5)); [ $w -gt 400 ] && { echo "$label SERVER FAIL" | tee -a "$R"; return; }; done

  # warmup pass (primes page cache + settles clocks), timing discarded
  seed=$((seed+1))
  node -e "const fs=require('fs');const w=JSON.parse(fs.readFileSync('$SP/bench_480p_5s.api.json','utf8'));w['15'].inputs.noise_seed=$seed;w['92'].inputs.filename_prefix='video/ab_warm';fs.writeFileSync('$SP/ab_tmp.json',JSON.stringify(w));"
  ( cd "F:/pinokio/api/comfy.git" && node comfy-api.js run "$SP/ab_tmp.json" --url http://127.0.0.1:8189 --out "$SP/ab_out" --timeout 3000 >/dev/null 2>&1 )

  # measured pass
  seed=$((seed+1))
  node -e "const fs=require('fs');const w=JSON.parse(fs.readFileSync('$SP/bench_480p_5s.api.json','utf8'));w['15'].inputs.noise_seed=$seed;w['92'].inputs.filename_prefix='video/ab_m';fs.writeFileSync('$SP/ab_tmp.json',JSON.stringify(w));"
  local s=$(date +%s)
  ( cd "F:/pinokio/api/comfy.git" && node comfy-api.js run "$SP/ab_tmp.json" --url http://127.0.0.1:8189 --out "$SP/ab_out" --timeout 3000 >/dev/null 2>&1 )
  local e=$(date +%s)
  local sit=$(tr '\r' '\n' < "$log" | grep -oE "20/20 \[[0-9:]+<[0-9:]+, *[0-9.]+s/it\]" | tail -1 | grep -oE "[0-9.]+s/it")
  local pw=$(nvidia-smi --query-gpu=clocks.sm,temperature.gpu --format=csv,noheader)
  echo "$label  total=$((e-s))s  s/it=${sit:-?}  [$pw]" | tee -a "$R"
}

run "stock_r1" ""
run "sage_r1"  "--use-sage-attention"
run "stock_r2" ""
run "sage_r2"  "--use-sage-attention"
echo "=== AB COMPLETE ===" | tee -a "$R"
