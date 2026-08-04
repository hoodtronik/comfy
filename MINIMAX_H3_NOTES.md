# MiniMax H3 — measured notes for this machine

Working record for the Pinokio ComfyUI launcher at `F:\pinokio\api\comfy.git`.
Everything here was measured on this box unless explicitly marked as a projection.
User-facing setup instructions live in `README.md`; this file is the evidence behind them.

Companion notes from the RTX 4090 box: `hoodtronik/wan2gp-helper` → `MINIMAX_H3_GUIDE.md`
(private). That guide is the authority on **prompt format and creative behaviour**; this
file is the authority on **this machine's environment and timings**.

---

## 1. Environment

| | |
|---|---|
| GPU | RTX 6000 Ada Generation, 48 GB, compute capability **8.9** |
| RAM | 128 GB |
| ComfyUI | **0.30.0** (`app/`, branch `master`) |
| Python | 3.12.12 (conda env at `app/env`) |
| torch | **2.9.1+cu130** / torchvision 0.24.1+cu130 / torchaudio 2.9.1+cu130 |
| sageattention | **2.2.0+cu130torch2.9.1.post6** |
| triton-windows | 3.5.1.post24 |
| comfy-kitchen | 0.2.26 · comfy-aimdo 0.4.11 |

Rollback manifest for the pre-cu130 state (exact wheel URLs) is in the scratchpad
`rollback-torch-manifest.txt`; the pre-update app commit is tagged
`pre-update-2026-08-03`.

---

## 2. Quantization — what this GPU can and cannot do

Verified in code, not assumed:

```
supports_nvfp4_compute  False     # comfy/model_management.py requires props.major >= 10
supports_fp8_compute    True
```

After the cu130 upgrade ComfyUI logs at model load:

```
Native ops:   float8_e4m3fn, convrot_w4a4, int8_tensorwise, float8_e5m2
emulated ops: nvfp4, mxfp8
```

**NVFP4 is emulated on Ada** — it is a Blackwell (sm_100+) format. The official ComfyUI
template ships the NVFP4 text encoder as its default, and that default is wrong for this
hardware. Measured, identical prompt and seed, 608x352 / 56 f / 20 steps:

| text encoder | size | time |
|---|---|---|
| `qwen3vl_32b_minimax_h3_nvfp4_awq` | 14.6 GB | 78.9 s |
| `qwen3vl_32b_minimax_h3_int8_convrot` | 25.3 GB | **73.7 s** |

int8 wins **despite being 11 GB larger**, at comparable quality. The 4090 box reached the
same conclusion independently.

The text encoder runs **once per prompt**; the DiT runs every step. So encoder choice
barely moves throughput — it is a correctness/quality decision, not a speed one.

---

## 3. The cu130 upgrade

`comfy/quant_ops.py:40` disables comfy-kitchen's CUDA backend whenever
`torch.version.cuda < (13,)`. It is a blanket version check with no GPU-arch component,
and every CUDA-backend op is ungated by compute capability — so cu130 genuinely unlocks
it on Ada.

```
Found comfy_kitchen backend cuda: {'available': True, 'disabled': False}   # after
```

**What it cost.** No cu130 flash-attn wheels exist for Windows/cp312 (checked kingbri1,
cocktailpeanut/wheels, lldacing) and no cu130 xformers on the PyTorch index either.

- `flash_attn 2.8.3` → broken (DLL load failure). **Uninstalled.** A broken-but-installed
  package is worse than an absent one: it raises `ImportError` rather than
  `ModuleNotFoundError`, which defeats `try/except ImportError` guards. While it was
  present-but-broken it took out three *core* `comfy_extras` modules (`nodes_latent`,
  `nodes_post_processing`, `nodes_morphology`) via kornia. Removing it fixed all three.
- `cumesh` → broken (built against torch 2.8), which takes **ComfyUI-Trellis2** with it
  (`nodes.py` does a top-level `import cumesh`). ~74 node classes lost, 2354 → 2280.
  Accepted: user no longer uses Trellis2. Trellis2 does ship a
  `wheels/Windows/Torch2100/CUDA 13.1/` cumesh wheel, so **moving to torch 2.10.0+cu130
  would likely restore it** if that ever matters again.
- UltraShape partially degraded (`No module named 'flash_attn'`) but still registers.
- SageAttention, triton, deepspeed, bitsandbytes, comfy-kitchen all survived.

Net: 0 import failures after removing flash_attn.

---

## 4. SageAttention — the big win

The 4090 notes closed Sage as a dead end, correctly for the wheel they had:
`2.1.1+cu128torch2.7.0` ships **no SM89 kernel**, so it logs `Using sage attention`, then
at the first sampling step reports `SM89 kernel is not available ... using pytorch
attention instead` and **silently falls back**. The flag reads as enabled while doing
nothing.

The cu130 upgrade pulled `sageattention 2.2.0+cu130torch2.9.1.post6`, which **does** have
an SM89 kernel.

**Definitive measurement** — interleaved stock→sage→stock→sage on an idle machine,
864x480 / 124 f / 20 steps, warmup pass discarded, fresh seed per run:

| trial | s/it | total | GPU during sampling |
|---|---|---|---|
| stock r1 | 5.75 | 134 s | 945 MHz, 87 C, 298.8 W, 100% |
| **sage r1** | **4.15** | **101 s** | 1215 MHz, 87 C, 297.9 W, 100% |
| stock r2 | 5.76 | 132 s | 900 MHz, 88 C, 299.5 W, 100% |
| **sage r2** | **4.15** | **100 s** | 1050 MHz, 86 C, 296.7 W, 100% |

**-27.9% s/it, -24.4% wall clock.** Repeat rounds agree to 0.2% (stock) and 0.0% (sage) at
matched power and temperature.

Sage sustains **higher clocks at identical power draw** (1215/1050 vs 945/900 MHz at
~298 W) — int8 attention does more work per watt, and on a 300 W-capped card that becomes
clock headroom directly. A card with more power budget should benefit at least as much.

⚠️ Earlier passes produced 26%, 35% and 59% for this same comparison. All were invalid:
the machine was in desktop use and the configs ran in separate sessions at different
thermal states. Only the interleaved idle-machine figures above should be quoted.

Verified genuine, not a fallback: `Using sage attention` present, no `SM89` line anywhere
in the log, and a frame-level comparison against the stock render shows no degradation.
(The only `falling back` string in the log is an unrelated `cubvh → skimage` message.)

Enabled in `start-headless.js` only. Sage affects every model and perturbs attention
numerics slightly — same seed gives a near-identical but not bit-identical take — so
`start.js` keeps stock attention for interactive work.

⚠️ If torch is ever downgraded, this speedup **vanishes silently** rather than erroring.

---

## 4b. DiT quantization — fp8 is 48% SLOWER than int8 on this card

Interleaved, sage on, idle machine, 864x480 / 124 f / 20 steps:

| DiT | s/it | total | GPU during sampling |
|---|---|---|---|
| `fl2va_pruned_int8_convrot` | **4.15** | **100 s** | ~1110 MHz, 296.8 W |
| `fl2va_pruned_fp8_scaled` | 6.17 | 140 s | ~990 MHz, 293.7 W |

Rounds agree to 1.0% / 0.2%.

**`supports_fp8_compute` is True on sm_89 and `float8_e4m3fn` is in the native ops line,
yet fp8 is far slower.** The native-ops line is a *correctness* signal, not a performance
ranking. What matters is that `int8_convrot` lands on comfy-kitchen's optimized convrot
kernels (the ones cu130 unlocks); `fp8_scaled` takes a slower route.

fp8 also draws *less* power (293.7 W vs 296.8 W) while being slower — it is not saturating
the card, so unlike int8 it is not even power-limited. Stay on int8_convrot.

## 4c. INT4 is 27% faster and visibly worse — rejected

`MiniMax_H3_FL2VA_pruned_int4_convrot` (third-party, `Abiray/...`) loads fine and is the
fastest option measured: **3.01 s/it vs int8's 4.15** (77 s vs 100 s), i.e. 48% faster than
the stock-attention baseline we started from.

**It is still the wrong choice.** Same-seed comparison at 864x480/124f
(`docs/img/int8_vs_int4.png`):

| | int8_convrot | int4_convrot |
|---|---|---|
| s/it | 3.97 | 2.88 |
| output size | 900 KB | **2.9 MB** |

The 3x file size is the tell — that is grain, and noise does not compress. Visually the
INT4 render loses the background bokeh entirely, gains heavy grain across the whole frame,
takes on a muddy magenta cast, and smears the reflections that int8 renders cleanly.

It is **not usable as a fast preview either**, which would have been its fallback role: the
composition, lighting and depth differ enough from the int8 render that it does not predict
the final. A preview that does not predict the finish is worse than none.

Speed alone is not a result. Always frame-compare a quantization change at a fixed seed
before adopting it.

## 4d. EasyCache — real win, with a tuning rule that is not the threshold

Core ComfyUI node, model-agnostic, composes with H3's NestedTensor (video+audio) latent
without complaint. Measured 864x480/124f, sage on, int8 DiT:

| | skips | s/it | sampling | vs no-cache |
|---|---|---|---|---|
| no cache | 0/20 | 4.15 | 83.0 s | — |
| thr 0.2 | 9/20 | 2.25 | 45.0 s | **-45.8%** |
| thr 0.4 | 10/20 | 2.04 | 40.8 s | -50.8% |

**Skipped steps are essentially free here.** EasyCache claims 1.82x for 9 skips (=20/11);
measured 1.844x — ~101% realized. The 4090 box measured ~95% of its own claim. Both are
full realization; there is no resident-vs-streaming regime effect (an earlier claim that
there was came from a miscount — see §6b).

### The tuning rule: read the skip *sequence*, ignore the threshold

`reuse_threshold` is only weakly portable (thr 0.2 gives 9 skips here, 7 on the 4090 box).
What matters is the **run-length distribution**, extracted from the verbose log:

```
thr 0.2:  S R S R S R S S R S S R S S    runs [1,1,1,2,2,2]  max 2   -> clean
thr 0.4:  S R S S R S S S R S S S R S    runs [1,2,3,3,1]    max 3   -> under test
```

Consecutive reuse compounds: each reused step extrapolates from an already-extrapolated
state, so error grows with **run length**, not total count. Runs that terminate the window
are worst — nothing downstream corrects them.

**Safe operating envelope:** max consecutive run <= 2, `end_percent` < 1.0. Verify with a
fixed-seed frame comparison — and see the file-size caveat in §4f, which is important.

### Run-length isolation (the 4090 box could not force runs > 2; this box can)

Raising the threshold lengthens runs here. thr 0.6 and 0.8 produce **identical** sequences
(the dynamics saturate): 11 skips, runs [2,3,4,2], max 4, with `end_percent` 0.95 so the
final step always computes — i.e. **long runs with no tail**. Same seed (909090) throughout:

| variant | skips | runs | max | end | frame quality |
|---|---|---|---|---|---|
| no cache | 0 | — | — | — | sharp: rain ripples, defined reflections |
| thr 0.2 | 9 | 1,1,1,2,2,2 | 2 | 0.95 | mild softening |
| thr 0.4 | 10 | 1,2,3,3,1 | 3 | 0.95 | mild softening |
| **thr 0.6 / 0.8** | 11 | 2,3,4,2 | **4** | 0.95 | **badly smeared** — reflections collapse to blobs |
| thr 0.3 tail | 4 | 3,1 | 3 | **1.00** | close to no-cache |

**Run length degrades independently of tail placement.** Max-run 4 with nothing at the
tail is the worst output in the set, while a tail-inclusive run of 3 (only 4 skips) stayed
close to the control. That is the opposite ordering to the 4090 box, which found
`end_percent=1.0` to be the dominant knob — but their thresholds capped at max-run 2, so
they never tested run length. Both observations can hold: tail placement matters *and*
run length matters, and each box happened to be able to vary only one of them.

Degradation is not linear in run length — it looks like a threshold effect between 3 and 4
rather than steady decay, and runs of 2 vs 3 were hard to separate.

## 4f. The file-size heuristic is one-sided — it misses blur

§4c used output file size to catch INT4's degradation (2.9 MB vs 900 KB) and it worked.
**It does not generalize.** For the max-run-4 render above, file size was only **+18.6%**
over no-cache (1352 KB vs 1140 KB) — well inside what looked acceptable — while the frame
is visibly the worst in the set.

The reason: file size detects degradation that *adds* high-frequency content. INT4 added
grain, which inflates bitrate. Cache over-reuse **blurs**, and blur *compresses better*, so
it pushes file size the other way. The heuristic is a noise detector, not a quality
detector.

**Use it only to catch noise-type regressions. It cannot clear a blur-type one — that needs
frames.**

## 4e. `--fast` is a no-op on H3

| | s/it |
|---|---|
| baseline | 4.15 |
| `--fast fp16_accumulation` | 4.13 |
| `--fast` (all, incl. `fp8_matrix_mult`) | 4.14 |

All inside noise. The `fp8_matrix_mult` null is consistent with the fp8 DiT loss (§4b) —
the fp8 weight path is simply not where sm_89 wins are.

## 4g. TorchCompile needs MSVC 14.3x+ on PATH — it is a compiler-version issue

`TorchCompileModel` (inductor) fails out of the box here. Two distinct causes, and the
second one I initially misdiagnosed:

1. `RuntimeError: Compiler: cl is not found.` — inductor emits C++ and needs MSVC on
   Windows. Visual Studio is installed but not on PATH. Launch ComfyUI under
   `vcvars64.bat`.
2. With MSVC 14.29 (VS **2019**) available it gets further, then fails compiling triton's
   generated launcher:
   ```
   __triton_launcher.c(123): error C2059: syntax error: '}'
   __triton_launcher.c(131): error C2059: syntax error: '}'
   ```

**That is MSVC being too old for the C11 triton emits, not a CUDA problem.** The CUDA
headers resolved fine — there is no "cannot open include file" anywhere in the log.

⚠️ **Correction.** This was first recorded here as a CUDA toolkit mismatch (`CUDA_PATH` =
v12.8 vs torch cu130), inferred from the include paths in the failing command line without
reading `cl.exe`'s actual output. That was wrong, and it would have cost a ~3 GB toolkit
install that fixed nothing. The claim that the cu130 upgrade "broke torch.compile" was also
wrong — cu130 is unrelated to a C syntax error. **Read the compiler's own error text, not
the flags it was invoked with.**

**The fix costs nothing:** MSVC 14.44 (VS2022) is already installed on this machine, in
both `2022\BuildTools` and `2022\Community`. Use VS2022's `vcvars64.bat`:

```
C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat
```

An earlier scan reported only the 2019 toolset because it truncated a recursive search at
the first two hits — `vswhere.exe -products *` enumerates installs reliably instead.

## 5. Measured render times

Stock attention, warm server, uninterrupted sweep. All four verified as h264 + AAC
stereo at the correct duration.

| resolution | 5 s (124 f) | 10 s (243 f) |
|---|---|---|
| 864x480 | **2 m 25 s** (145 s, 5.5 s/it) | **6 m 18 s** (378 s, 17.2 s/it) |
| 1344x768 | **9 m 02 s** (542 s, 25.4 s/it) | **28 m 24 s** (1704 s, 81.3 s/it) |

With Sage, measured at 480p only: 5 s → **1 m 59 s**; 10 s sampling → 11.2–12.8 s/it.
**1344x768 with Sage has not been measured.** Scaling the sampling reduction suggests
~6½ min (5 s) and ~20 min (10 s) — projection, not data.

**Cost is quadratic in both axes, and resolution bites harder than duration.**
480p→1344x768 at 5 s is 3.7x; 5 s→10 s at 480p is 2.6x. A 1344x768/10 s clip is **11.7x**
a 480p/5 s one. Sweep at 480p, finish at 1344x768.

### Why this box is slower than the 4090

Not configuration — power. Under load:

```
power.draw 299.55 W / power.limit 300 W / power.max_limit 300 W
clocks.sm 780 MHz of 3105 MHz max
clocks_event_reasons.sw_power_cap  Active
hw_thermal_slowdown               Not Active
```

The limit **cannot be raised** (`max_limit` is also 300 W) and it is not thermal. A 450 W
4090 runs the same workload ~1.35–1.6x faster despite half the VRAM. The gap narrows as
the work gets heavier (1.6x at 480p/5 s → 1.35x at 1344x768/10 s).

### VRAM is not the bottleneck

| flags | s/it |
|---|---|
| default | 5.75 |
| `--highvram` | 5.80 |
| `--disable-dynamic-vram` | 5.85 |

No VRAM strategy helps. Peak usage is ~40 GB of 48 GB with GPU utilization at 100% and
`sw_power_cap` active — the card is compute/power-bound. The 48 GB buys **capability**
(no RAM-streaming tax, no OOM at native resolution) rather than throughput. On the 24 GB
4090, comfy-aimdo has to stream 45 GB of weights from system RAM; this box does not.

---

## 6. Measurement traps hit while producing the numbers above

Recorded because each one produced a wrong number before being caught.

1. **ComfyUI caches prompt execution.** Re-running a byte-identical workflow returns the
   cached result in ~1 s without executing. Change the seed to force a real run.
2. **OS page cache dominates the totals.** The 25 GB encoder reloads between runs. When
   it is in the page cache (128 GB RAM) overhead is ~34 s; when evicted it is ~400–700 s.
   Running a 20 GB download concurrently with a timing run evicts it and inflates totals
   by minutes. `s/it` isolates sampling and is the metric to trust; totals are only
   comparable between runs under identical cache conditions.
3. **`s/it` climbs during a run.** Comparing a step-4 reading against another run's final
   figure is invalid — it briefly made `--highvram` look 5% faster when it is in fact
   slightly slower.
4. **`nvidia-smi` cannot report per-process VRAM on Windows** (WDDM shows `[N/A]`); map
   PIDs to processes separately.
5. **`xargs du -ch` with empty input** sizes the current directory instead of nothing,
   which briefly looked like a 388 GB runaway download.

---

## 6b. Two phantom results, and the checks that would have killed them

Both were produced today by careful-looking work. Recording the *checks*, not just the
corrections, because the failure mode is confident wrong numbers rather than obvious ones.

**Phantom 1 — "cache methods pay more on a streaming card."** A whole mechanism was built
on it (skipped step also skips a weight-stream pass), it was inverted once when data
disagreed, and then it evaporated: the 4090 box's skip count came from
`grep "skipping step"`, which also matches EasyCache's `NOT skipping step` lines. 14
"skips" were really 14 *decisions*. Real counts gave ~95% realized there vs ~101% here —
no regime effect at all.

- **The check:** EasyCache prints its own `EasyCache - skipped N/20 steps (X.XXx speedup)`
  summary. Assert any parse against it and refuse to report on mismatch.
- **The deeper check:** compute realized fraction as `measured / the tool's own claimed
  speedup`, **per box**. Never compare raw speedups across machines with different
  baselines — that cross-box comparison was the actual bug, more than the grep.

**Phantom 2 — the Sage magnitude, reported at 26%, 35% and 59% before it was real.** All
taken while the machine was in desktop use, with configs run in separate sessions at
different thermal states. Interleaved on an idle box: 27.9%, rounds agreeing to 0.2%.

- **The check:** interleave A-B-A-B back to back, never batch; require repeated rounds of
  the same config to agree before reporting.

The `NOT skipping` trap has a second edge: a *deliberate* parser written here matched
`(not )?` in lowercase, and EasyCache logs uppercase `NOT`, so every not-skip line fell
through silently and produced all-S sequences with max-run = total. It cross-validated as
wrong only because the summary-line assert caught it. `bench/skipmap.sh` has the working
version.

## 7. Storage layout

`install.js` junctions most of `models/` onto Pinokio's shared drive, so the physical
disk is not always the launcher's own:

- `vae/`, `checkpoints/`, `loras/`, `unet/`, `controlnet/` and ~11 others →
  **junctions to `C:\pinokio\drive\drives\peers\d1756217092254\...`**
- `diffusion_models/`, `text_encoders/` → real directories on **F:**

So the two H3 VAEs (5.4 GB) landed on C: while the encoder and DiT (60 GB) landed on F:.
Check `Get-Item models/<dir>` before a large download if a drive is tight.

⚠️ **Do not set `HF_HUB_ENABLE_HF_TRANSFER=1`.** If interrupted it truncates the
`.incomplete` and restarts from zero rather than resuming. Finalization also sits at full
size with no output for several minutes on a ~20 GB file — normal, not a hang.

Also present: ~50 GB of stale `.incomplete` partials under `models/flash_portrait/` from
an old FlashPortrait/Wan2.1 fetch that never finished. Pre-existing; easy space to
reclaim.

---

## 8. Local source patches

Kept in `patches/`, marked in-code with `CLAUDE-NOTE:`. Reapply after an update that
touches these files: `git apply --3way patches/<name>.patch`.

- `ltx-embeddings-connector-device.patch` — LTX device-mismatch fix. Upstream still has
  not fixed this as of v0.30.0.
- `ltxvideo-gemma-single-file-loader.patch` — single-file Gemma encoder support. Upstream
  dropped the `load_torch_file` import this depends on during their refactor; the import
  is restored locally.
- `trellis2-modelname-and-clamp.patch` — short model-name alias + divide-by-zero clamp.

`update.js` uses `git pull --autostash` so these no longer block the Update button.

---

## 9. Open / untested

- ⏳ **fp8 DiT** — `minimax_h3_fl2va_pruned_fp8_scaled` (19.5 GB) is downloaded but not
  yet benchmarked. FP8 is **native** on Ada (`float8_e4m3fn` in native ops), and the 4090
  notes never tested it, so this is a genuine unknown rather than a re-confirmation.
- ⏳ 1344x768 with Sage — not measured, only projected.
- ⏳ `--disable-async-offload` — the trial errored; no trustworthy number.
- ⏳ INT4 convrot variants from `Abiray/Minimax-H3-nvfp4-INT4-INT8-Convrot` (13.9 GB
  encoder, 10.6 GB DiT, 11.6 GB mixed int4/int8). Third-party re-quants, not official.
  `convrot_w4a4` is in the native op list, so the path is supported.
- ❌ GGUF (`realrebelai/MiniMax-H3_GGUFs`) — needs city96's ComfyUI-GGUF, not installed,
  and GGUF support for a brand-new architecture is not a given.
- ⏳ Whether `MiniMaxH3SigmaShift` is worth tuning (the official template does not use it;
  model default shift is 12.0 video / 3.0 audio).
