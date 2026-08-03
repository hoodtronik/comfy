#!/bin/bash
# Usage: skipmap.sh <server.log>
# EasyCache logs "- skipping step" and "- NOT skipping step" (uppercase NOT).
# A naive grep for "skipping step" catches BOTH and inflates the count - that is exactly
# the miscount that produced a phantom result. Anchor on the decision word, then
# cross-validate the total against EasyCache's own summary line.
L="$1"
auth=$(grep -oE "EasyCache - skipped [0-9]+/" "$L" | tail -1 | grep -oE "[0-9]+")
seq=$(tr '\r' '\n' < "$L" | sed 's/\x1b\[[0-9;]*m//g' \
      | grep -oE "EasyCache \[verbose\] - (NOT )?skipping step" \
      | sed 's/.*- NOT skipping step/R/; s/.*- skipping step/S/' | tr -d '\n')
half=$(( ${#seq} / 2 ))
one=${seq:$half}                      # 2nd half = measured run (1st = warmup)
cnt=$(echo -n "$one" | tr -cd 'S' | wc -c)
maxrun=$(echo -n "$one" | grep -oE 'S+' | awk '{if(length($0)>m)m=length($0)}END{print m+0}')
runs=$(echo -n "$one" | grep -oE 'S+' | awk '{printf "%d ",length($0)}')
echo "  sequence : $one"
echo "  skips    : $cnt   (EasyCache reports: ${auth:-?})"
echo "  run len  : ${runs:-none}   max=$maxrun"
if [ "$cnt" = "$auth" ]; then echo "  cross-validated OK"; else echo "  MISMATCH - do not trust"; fi
