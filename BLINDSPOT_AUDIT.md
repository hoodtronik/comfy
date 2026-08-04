# Blind-spot audit — 2026-08-04

Re-evaluation of every claim from the 2026-08-03 session, with two demotions applied:
1. **4090 data counts as secondary.** Different card (450 W vs 300 W cap, 24 GB vs 48 GB,
   streaming vs resident), different prompts/seeds on their quality tests.
2. **Anything measured before ~16:45 on 08-03 is contaminated-era** (user was working on
   the machine; identical runs swung up to 2x from desktop load).

## Tier 1 — verified clean on THIS box (idle, interleaved, fresh seeds). Trust these.

| claim | evidence |
|---|---|
| Sage −27.9% s/it @ 864x480/124f | 5.75/5.76 vs 4.15/4.15, rounds agree ≤0.2% |
| EasyCache 0.2: −45.8% sampling, 9/20 skips, ~101% realized | vs same-session no-cache |
| fp8 DiT 48% slower than int8 (sage on) | 6.17/6.16 vs 4.17/4.13 |
| INT4 DiT visibly degraded (same seed) | frame grid committed |
| `--fast` no-op (all opts) | 4.13/4.14 vs 4.15 |
| Run of 4 mid-window smears badly; runs ≤2 mild | same-seed frames, p8/p10 |
| Native+sage: 15.35 s/it (5 s), 42.97 s/it (10 s) | clean runs |
| TorchCompile incompatible with int8_convrot | DLPack/FakeTensor, architectural |
| ECC already Disabled on this card | nvidia-smi, 08-04 |

## Tier 2 — DEMOTED: contaminated-era measurements presented as findings

These were single, non-interleaved runs during desktop use. The deltas are inside the
noise band that era produced elsewhere. **The README/notes stated them too strongly.**

1. **"int8 TE faster than nvfp4 TE (73.7 s vs 78.9 s)."** A 6.7% delta from single
   contaminated runs in separate sessions. The *mechanism* argument stands on code fact
   (`supports_nvfp4_compute: False` → nvfp4 emulated), so int8 remains the right default —
   but the measured-speed claim is unverified and has propagated to the README, the notes,
   and the 4090 handoff. → **RETEST clean, interleaved.**
2. **"VRAM flags make no difference" (5.75 / 5.80 / 5.85).** ≤1.7% deltas, sequential not
   interleaved, contaminated era. Probably true, but "measured useless" was overclaimed —
   and `--disable-async-offload` errored and was never re-run at all, so async offload
   (on by default, 2 streams) is genuinely *untested*. → **RETEST; settle async-offload.**
3. **480p/10 s stock = 17.2 s/it; native stock = 25.4 / 81.3 s/it.** All contaminated.
   Consequence: **the Sage gain at native resolution was never measured** — 15.35 clean
   vs 25.4 dirty implies −40%, larger than 480p's −27.9% (consistent with fixed-cost
   dilution), but that comparison is dirty-vs-clean and cannot be quoted.
   → **Clean native stock pair is the single most valuable missing number.**

## Tier 3 — DEMOTED: imported from the 4090 without local verification

1. **`end_percent < 1.0` as "the single most important knob."** Their finding, their
   prompt/seed. My only tail test (thr 0.3, [0.65,1.0], 4 skips, run-3 tail) came back
   **near-clean — mildly contradicting it on this box**. The guide's safe envelope
   currently encodes their rule. → **TEST tail vs no-tail at matched run length here.**
2. **Draft-then-upscale beats native** (their ~1 min → 1728x960 vs 3.2 min native 720p).
   Entirely their stack (Topaz). **SeedVR2 is installed here** — the claim is testable
   locally and changes production workflow if true. → **TEST with SeedVR2.**
3. **Threshold portability** ("0.2 ≈ 7-9 skips everywhere"). Two boxes, one resolution.
   Whether the *same box* holds skip patterns across resolutions/durations is unknown, and
   that is the version that matters for production. → **TEST EC at native res + 10 s.**
4. Sage "expect more on higher power budget" — their −33% vs my −27.9% fits the story,
   but the local version (does Sage's gain grow at native res, where compute per step is
   larger?) is unmeasured. Same experiment as Tier 2 #3.

## Tier 4 — never examined at all

1. **Audio.** Every quality comparison was video frames only. H3's whole selling point is
   joint audio, and EasyCache skips steps of a *joint* AV latent — cache artifacts could
   land in the audio track invisibly. Never checked on any variant.
   → **Compare audio across nocache / EC0.2 / EC-aggressive** (waveform stats + spectrogram
   via ffmpeg astats/showspectrumpic; flag anything anomalous for human ears).
2. **Single-seed quality verdicts.** The run-length cliff (3→4) rests on one seed/prompt.
   The 4090 itself warned content-dependence is the alternative hypothesis.
   → **Repeat nocache / EC0.2 / thr0.6 at 2 more seeds.**
3. **`--enable-triton-backend`.** comfy-kitchen's triton backend reports
   `available: True, disabled: True` on every boot — it needs an explicit flag, and with
   triton 3.5.1 installed it has never been tried. Could plausibly interact with the int8
   path either way. → **One A/B trial** (crash-guarded).
4. **thr saturation.** 0.6 and 0.8 produced identical sequences (11/20). Is 11 the ceiling
   of the dynamics? One cheap trial at a higher threshold answers it.

## Non-issues confirmed while auditing

- ECC: already Disabled (pro-card default would have cost bandwidth; it is off).
- Power cap 300 W hard: re-confirmed under clean load, `sw_power_cap` active at 100% util.
- The two self-inflicted diagnostic errors (CUDA-mismatch misdiagnosis, sage-number
  churn) are recorded in the notes and memory; checks are in the harness.
