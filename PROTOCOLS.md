# PROTOCOLS — resume point for H3 performance testing

Trigger: user says **"run protocols"**.

Read this file, then `MINIMAX_H3_NOTES.md` (environment + findings) before touching
anything. Everything below was left in a known-good, committed state.

---

## 0. Preconditions — check these FIRST, do not skip

The entire reason testing was paused: **benchmark numbers taken while the user is working
on the PC are worthless.** Concurrent GPU work (Blender, browsers) cost identical stock
runs 5.5 vs 10.47 s/it — a 2x swing that swamps every effect being measured.

Before any timing run:

```bash
nvidia-smi --query-gpu=utilization.gpu,memory.used,power.draw,clocks.sm,temperature.gpu --format=csv,noheader
```

- GPU utilization should be **near 0%** and memory near 0 with ComfyUI stopped.
- If other GPU apps are running (check for `blender`, browsers), **ask the user before
  proceeding** — do not silently produce contaminated numbers.
- Confirm the user is done for the day / not using the machine.

If the machine is busy, either wait or state explicitly that results are "typical under
desktop load", never presenting them as clean.

---

## 1. Current state (all committed and pushed to `fork` = hoodtronik/comfy, branch main)

- ComfyUI **0.30.0**, torch **2.9.1+cu130**, sageattention **2.2.0+cu130torch2.9.1.post6**,
  triton-windows 3.5.1.post24. Python 3.12 at `app/env`.
- MiniMax H3 **working end to end** — verified h264 + AAC stereo.
- `start-headless.js` runs on its own `{{port}}` with `--disable-auto-launch`,
  `--use-sage-attention`, `PYTHONIOENCODING=utf-8`; writes endpoint to `headless.json`.
- `comfy-api.js` drives it: `node comfy-api.js run <wf.api.json> --url <endpoint>`.
- Models present (all in `app/models/`):
  - encoders: `qwen3vl_32b_minimax_h3_int8_convrot` (in use), `..._nvfp4_awq` (wrong for
    this GPU, kept for reference), `..._int4_convrot` (third-party, untested)
  - DiT: `fl2va_pruned_int8_convrot` (in use), `fl2va_pruned_fp8_scaled` (untested),
    `MiniMax_H3_FL2VA_pruned_int4_convrot` (third-party, untested),
    `ref2va_pruned_int8_convrot` (untested — unlocks `MiniMaxH3ReferenceToVideo`)
  - both VAEs (these live on C: via a junction, unlike the rest)

  ⚠️ The INT4 files come from `Abiray/Minimax-H3-nvfp4-INT4-INT8-Convrot`, a third-party
  re-quant, not Comfy-Org. Verify they load before trusting any output. The mechanism is
  sound — `convrot_w4a4` is in this card's **native** op list — but nothing is verified.
  Note Abiray stores DiT files at the repo root, not under `diffusion_models/`.
- flash_attn **uninstalled** (broken post-cu130, was poisoning core `comfy_extras` imports).
  Trellis2 lost with it (cumesh built for torch 2.8) — user confirmed it is no longer used.

### Start the server for testing

```bash
cd F:/pinokio/api/comfy.git/app
TOKENIZERS_PARALLELISM=false PYTHONIOENCODING=utf-8 \
  ./env/python.exe main.py --port 8189 --disable-auto-launch [--use-sage-attention] \
  > <scratch>/boot.log 2>&1 &
# wait for: "To see the GUI go to"
```

Stop it with PowerShell before switching flags — torch DLLs stay locked while it runs:

```powershell
Get-Process python | Where-Object { $_.Path -like "F:\pinokio\api\comfy.git\*" } | Stop-Process -Force
```

---

## 2. Measurement discipline — non-negotiable, these each produced a wrong number

1. **Change the seed every run.** ComfyUI returns a cached result in ~1 s for a
   byte-identical workflow. A 1 s "render" is a cache hit, not a result.
2. **Compare `s/it`, not wall-clock totals.** Totals are dominated by whether the 25 GB
   encoder is in the OS page cache (~34 s vs ~400-700 s of overhead). Sage once posted a
   *higher* total than stock while being twice as fast per step.
3. **Never quote a mid-run `s/it`** — it climbs through a run. Use the final `20/20` line.
4. **Interleave configs** (A → B → A → B) rather than batching. Two rounds minimum; if the
   two rounds of the same config disagree, the data is contaminated — do not report it.
5. **Run a warmup pass first** and discard its timing, to prime the page cache.
6. Nothing else on the GPU. No concurrent downloads (they evict the page cache).

Reusable harness: `<scratch>/sage_ab.sh` implements all of the above (interleaved, warmup
+ measured pass, fresh seeds, logs clocks/temp per trial). Adapt it rather than rewriting.

---

## 2b. STATUS 2026-08-04 — the performance sweep is DONE

Every lever is resolved. **Do not re-run these.** Full evidence in `MINIMAX_H3_NOTES.md`.

| lever | verdict |
|---|---|
| SageAttention | ✅ **-27.9% s/it**, enabled in `start-headless.js` |
| EasyCache thr 0.2 | ✅ **-45.8%** sampling, 9/20 skips, max run 2 |
| fp8 DiT | ❌ 48% slower than int8 |
| INT4 DiT | ❌ visibly degraded |
| nvfp4 TE | ❌ emulated on sm_89 |
| `--fast` (all) | ❌ no-op |
| VRAM flags | ❌ no effect |
| TorchCompile | ⛔ architecturally incompatible with int8_convrot |

Keep `fl2va_pruned_int8_convrot` + `qwen3vl_32b_int8_convrot` + Sage. Stacked, 480p/5 s
went **134 s → 61 s**; native 1344x768/10 s is **15 m 18 s**.

**What is actually left** is creative/workflow work, not optimization:

1. **ref2va lane untested.** `workflows/api/minimax_h3_ref2va.api.json` is written and
   points at the cyborg turnarounds in `app/input/`, but has never been executed. Storyboard
   references are first-class (`<Picture N>` = composition anchor; character sheets go inside
   `<Subject N>` instead).
2. **Draft-then-upscale vs native.** The 4090 box measured draft+upscale (~1 min ->
   1728x960) beating native 720p (3.2 min -> 1280x720) — better resolution, a third of the
   time. Untested here and it changes the production workflow, not just settings.
3. **EasyCache quality at thr 0.2 for final renders** — measured mild softening vs no-cache.
   Fine for drafts; decide per-shot whether finals take the hit.

## 3. Outstanding work (optimization — ALL RESOLVED, kept for the record)

### 3.1 Finish the SageAttention A/B (highest value — blocks a briefing to the user's other machine)

Round 1 completed but is **untrustworthy** (machine in use): stock 10.47 s/it vs sage
4.25 s/it. Earlier, less controlled runs gave stock 5.5-5.75 and sage 4.07. The observed
"speedup" therefore ranges 26-59% depending on which pair is compared. **Need a clean
interleaved number.**

```bash
bash <scratch>/sage_ab.sh    # stock/sage x2 at 864x480/124f, ~25 min
```

Success = the two stock rounds agree with each other and the two sage rounds agree.
Then update: `MINIMAX_H3_NOTES.md` §4, `README.md`, and the handoff doc in §4 below.

### 3.2 fp8 DiT vs int8 DiT

`minimax_h3_fl2va_pruned_fp8_scaled.safetensors` is downloaded (20 GB) and untested.
FP8 is **native** on this card (`supports_fp8_compute: True`, `float8_e4m3fn` in the
native ops line), and the user's other machine never evaluated it — genuine unknown.

Swap `w['6'].inputs.unet_name` in the workflow, interleave against int8, same discipline.
Pairs naturally with `--fast fp8_matrix_mult`.

### 3.3 EasyCache / LazyCache

Core ComfyUI nodes, **model-agnostic** step-skipping — should apply to H3 without
H3-specific support. Inputs: `model`, `reuse_threshold`, `start_percent`, `end_percent`,
`verbose`. Insert between `UNETLoader` and `BasicGuider`. Cache methods trade quality for
speed **by construction**, so frame-compare, do not just time it. `LazyCache` is the
"universal compatibility" fallback.

### 3.4 `--fast` flags

Values: `fp16_accumulation`, `fp8_matrix_mult`, `cublas_ops`, `autotune`. ComfyUI's own
help calls these "untested and potentially quality deteriorating ... might crash your
comfyui" — so A/B individually with frame comparison, not all at once.

### 3.5 TorchCompileModel

Core node, triton 3.5.1 present. Expect a long first-run compile; measure the second run.

### 3.6 1344x768 with Sage

Never measured — the ~6.5 min / ~20 min figures in the docs are **projections** and are
labelled as such. Replace with real numbers.

### 3.7 INT4 variants (third-party — verify before trusting)

`qwen3vl_32b_minimax_h3_int4_convrot` (13.9 GB) and
`MiniMax_H3_FL2VA_pruned_int4_convrot` (10.6 GB), from
`Abiray/Minimax-H3-nvfp4-INT4-INT8-Convrot`. **First check they load at all**, then
frame-compare against int8 before judging on speed — a quantization this aggressive can
cost quality, and these are not official Comfy-Org builds.

### 3.8 ref2va lane (`MiniMaxH3ReferenceToVideo`)

Checkpoint now present. Needs a separate API workflow — the node takes reference images /
videos / audio instead of `first_frame`/`last_frame`, and the prompt uses the **six-section
ref guide format**, not the three-field T2V format (see the user's 4090 guide §6.4).

Per those notes: ref2va reference blocks carry **no `resolved_frame_index`**, so the
opening is a *soft* anchor, whereas FL2VA's first frame is pixel-pinned at frame 0.
Different tool, not an upgrade — measure which suits a given shot rather than assuming.
Also `ref_image_size: max` makes reference tokens ride through every sampling step and can
be several times slower than `match`.

### 3.7 Not worth revisiting

- VRAM flags (`--highvram`, `--disable-dynamic-vram`): measured, no benefit — card is
  compute/power-bound at 300 W with ~9 GB VRAM spare.
- SageAttention 3: FP4/Blackwell-only, impossible on compute 8.9.
- flash-attn / xformers: no cu130 Windows wheels exist.
- GGUF quants: need city96's ComfyUI-GGUF (not installed), H3 support unlikely.

---

## 4. Deliverable waiting to be sent

`<scratch>/HANDOFF_TO_4090_AGENT.md` — briefing for the agent on the user's RTX 4090 box
(`hoodtronik/wan2gp-helper`, private, **read-only**, needs `gh api` not the plain API).

It is **complete and sendable as-is**. Its Sage magnitude is deliberately given as a
range with an explicit "measure it yourself" instruction, because of the contamination
above. If §3.1 produces a clean number, update §1 of that doc before the user sends it.

Its headline is binary and already certain: their `2.1.1+cu128torch2.7.0` has no SM89
kernel and silently falls back; `2.2.0+cu130torch2.9.1.post6` does have one. Their 4090 is
also compute capability 8.9 and also on torch 2.9.1+cu130, so it drops straight in.

---

## 5. Useful paths

| | |
|---|---|
| launcher | `F:\pinokio\api\comfy.git` |
| workflows | `workflows/api/minimax_h3_t2v.api.json` (1344x768, structured prompt) |
| bench workflows | `<scratch>/bench_480p_5s.api.json`, `bench_480p_10s.api.json` |
| A/B harness | `<scratch>/sage_ab.sh` |
| rollback | app tag `pre-update-2026-08-03`; `<scratch>/rollback-torch-manifest.txt` |
| git | `origin` = pinokiofactory/comfy (upstream), `fork` = hoodtronik/comfy (push here) |

`<scratch>` = the session scratchpad; if a new session has a different one, the bench
workflows are trivially regenerated from `workflows/api/minimax_h3_t2v.api.json` by
setting width/height/length and a fresh seed.
