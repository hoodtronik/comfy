# Comfyui

A pinokio script for https://github.com/comfyanonymous/ComfyUI

ComfyUI is a node-graph interface and backend for diffusion models — image, video, and
3D generation built as a graph of nodes rather than a fixed pipeline. This launcher
installs it, keeps it updated, and can run it in two independent modes.

## Two ways to run

| | Manual | Headless |
|---|---|---|
| Menu item | **Start** | **Start Headless** |
| Script | `start.js` | `start-headless.js` |
| Port | ComfyUI default (8188) | next free port, published to `headless.json` |
| Browser | opens the Web UI | never auto-launches |
| Intended for | you, working in the graph editor | agents/scripts driving the HTTP API |

They are separate instances and can run at the same time. They share `app/models`,
`app/output`, and the ComfyUI-Manager node set, so anything installed or generated in
one is visible to the other.

**A note on VRAM:** both instances load models into the same GPU. Running a large
workflow in both at once will contend for VRAM. If you are generating manually and want
an agent to work in parallel, keep the headless workloads small — or stop one first.

### Manual

Click **Start**, then **Open Web UI**. This is ordinary ComfyUI.

### Headless

Click **Start Headless**. It picks the next free port, so it never collides with a
manual session, and writes the resolved endpoint to `headless.json` in this folder:

```json
{ "url": "http://127.0.0.1:8189", "port": "8189" }
```

That file is the discovery mechanism — external tools read it instead of guessing a
port. It is gitignored, and only exists while the headless script is running.

## comfy-api.js

A dependency-free CLI wrapper over ComfyUI's HTTP API, for driving the headless
instance. It resolves the endpoint automatically from `headless.json`.

```bash
node comfy-api.js status                      # version, GPU, VRAM, queue depth
node comfy-api.js nodes [filter]              # list installed node classes
node comfy-api.js run workflow.api.json       # queue a workflow, save its outputs
```

Options: `--url <endpoint>` to target a specific server (e.g. the manual instance on
8188), `--out <dir>` for where outputs land (default `app/output`), `--timeout <seconds>`
(default 600).

Endpoint resolution order: `--url` → `$COMFY_URL` → `headless.json` → `http://127.0.0.1:8188`.

### Workflows must be in API format

`run` takes an **API-format** workflow, not the format the Web UI saves by default.
In ComfyUI: **Workflow → Export (API)**. The plain "Save" format has `nodes`/`links`
arrays and will not execute; `comfy-api.js` detects this and tells you rather than
failing obscurely.

## API

ComfyUI's own HTTP API. Everything below assumes the headless endpoint from
`headless.json`; substitute `8188` to talk to the manual instance.

Core routes:

- `POST /prompt` — queue a workflow. Body `{"prompt": <api-format graph>, "client_id": "<id>"}`. Returns `{"prompt_id": ...}`.
- `GET /history/{prompt_id}` — job status and outputs. The entry appears while still running; check `status.completed`.
- `GET /view?filename=&subfolder=&type=output` — download a produced file.
- `GET /object_info` — every installed node class and its input schema.
- `GET /system_stats` — version, device, VRAM.
- `GET /queue` — running and pending jobs.

### curl

```bash
URL=$(python -c "import json;print(json.load(open('headless.json'))['url'])")

# queue a workflow
PROMPT_ID=$(curl -s -X POST "$URL/prompt" \
  -H 'Content-Type: application/json' \
  -d "{\"prompt\": $(cat workflow.api.json), \"client_id\": \"curl-demo\"}" \
  | python -c "import json,sys;print(json.load(sys.stdin)['prompt_id'])")

# poll until it reports completed
until curl -s "$URL/history/$PROMPT_ID" | grep -q '"completed": true'; do sleep 2; done

# fetch the first output image
curl -s "$URL/history/$PROMPT_ID" \
  | python -c "import json,sys;h=json.load(sys.stdin);print([i['filename'] for o in list(h.values())[0]['outputs'].values() for i in o.get('images',[])][0])"
```

### Python

```python
import json, time, urllib.parse, requests

url = json.load(open("headless.json"))["url"]
workflow = json.load(open("workflow.api.json"))

prompt_id = requests.post(
    f"{url}/prompt",
    json={"prompt": workflow, "client_id": "python-demo"},
).json()["prompt_id"]

while True:
    entry = requests.get(f"{url}/history/{prompt_id}").json().get(prompt_id)
    if entry and entry.get("status", {}).get("completed"):
        break
    time.sleep(1)

for node_output in entry["outputs"].values():
    for image in node_output.get("images", []):
        qs = urllib.parse.urlencode({
            "filename": image["filename"],
            "subfolder": image.get("subfolder", ""),
            "type": image.get("type", "output"),
        })
        data = requests.get(f"{url}/view?{qs}").content
        open(image["filename"], "wb").write(data)
        print("saved", image["filename"])
```

### JavaScript

```javascript
const fs = require('fs')

const { url } = JSON.parse(fs.readFileSync('headless.json', 'utf8'))
const workflow = JSON.parse(fs.readFileSync('workflow.api.json', 'utf8'))

const { prompt_id } = await (await fetch(`${url}/prompt`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ prompt: workflow, client_id: 'js-demo' }),
})).json()

let entry
while (!entry?.status?.completed) {
  await new Promise((r) => setTimeout(r, 1000))
  entry = (await (await fetch(`${url}/history/${prompt_id}`)).json())[prompt_id]
}

for (const output of Object.values(entry.outputs)) {
  for (const image of output.images ?? []) {
    const qs = new URLSearchParams({
      filename: image.filename,
      subfolder: image.subfolder ?? '',
      type: image.type ?? 'output',
    })
    const buf = Buffer.from(await (await fetch(`${url}/view?${qs}`)).arrayBuffer())
    fs.writeFileSync(image.filename, buf)
    console.log('saved', image.filename)
  }
}
```

## MiniMax H3

MiniMax H3 is supported natively by ComfyUI v0.30.0 — no custom nodes required. It
generates video with **native stereo audio** in a single joint pass (not layered on
afterward), up to 2K, 24fps, ~15s.

`workflows/api/minimax_h3_t2v.api.json` is a ready-to-run API-format text-to-video
workflow:

```bash
node comfy-api.js run workflows/api/minimax_h3_t2v.api.json --out ./results
```

### Which quantization on this machine

This box is an **RTX 6000 Ada (compute 8.9)**. That matters: NVFP4 is a Blackwell
format, and Ada has no native FP4, so the NVFP4 weights run through emulated
dequantization. Measured on an identical prompt/seed at 608x352, 56 frames, 20 steps:

| text encoder | size | time |
|---|---|---|
| `qwen3vl_32b_minimax_h3_nvfp4_awq` | 14.6 GB | 78.9 s |
| `qwen3vl_32b_minimax_h3_int8_convrot` | 25.3 GB | **73.7 s** |

int8 is faster *despite* being 11 GB larger, and output quality was comparable. The
workflow therefore ships with the **int8_convrot** encoder. On a Blackwell card the
NVFP4 file would be the better pick — this is a per-GPU choice, not a global one.

Note the text encoder runs once per prompt while the diffusion model runs every step,
so the encoder choice barely moves throughput. Sampling cost (~3.1 s/it here) is driven
by the diffusion model and the available quantization kernels.

### Prompts are structured, not prose

H3 was trained on the structured output of its own rewriter. Free-prose direction
underuses it badly. A text-to-video prompt is three labelled fields separated by blank
lines:

```text
integrated_multimodal_description: [Shot 1] Live-action, cinematic. <visuals, action,
camera along the timeline>. [Shot 2] At 00:02.500, the shot cuts to <...>

overall_soundscape: <1-4 sentences of ambience / physical / non-verbal sound only.
No dialogue. N/A only for deliberate silence.>

non_diegetic_music: <1-3 sentences of audience-only score: instrumentation, tempo,
dynamics. No mood words. N/A if none.>
```

- `[Shot 1]` carries no timestamp; later shots take strictly increasing ones
  (`[Shot 2] At 00:02.500, the camera cuts to ...`).
- Camera is written as natural English inside the shot — motion type, then amplitude,
  then speed: *"the camera pushes in with small amplitude at slow speed"*. Never stack
  labels at the end.
- Dialogue uses `<d>` tags with stable speaker IDs. Identity, action and delivery go
  **outside** the tag; only the language tag and verbatim words go inside:
  `The woman (S1) says: <d>[English] I get off at the next station.</d>`

**There is no negative prompt.** `BasicGuider` takes a single conditioning and there is
no CFG, so anything you don't want has to be handled by not asking for it.

### Frame count must land on the 17k+5 grid

`length` must satisfy `n % 17 == 5`; the node snaps upward silently, so an off-grid
value quietly becomes something else. At 24fps:

| seconds | frames | actual |
|---|---|---|
| 5 | 124 | 5.17 s |
| 8 | 192 | 8.00 s |
| 10 | 243 | 10.13 s |
| 15 | 362 | 15.08 s (max trained) |

Cost is **quadratic in sequence length**, so 15s costs roughly twice the wall clock of
10s for 1.5x the footage. Trained range is ~124-362; beyond that is untested.

### Measured render times

RTX 6000 Ada (48 GB), torch 2.9.1+cu130, int8 encoder + pruned int8_convrot DiT,
20 steps, `res_multistep` / `simple`:

| resolution | duration | frames | time | s/it |
|---|---|---|---|---|
| 864x480 | 5 s | 124 | 2 m 25 s | 5.5 |
| 864x480 | 10 s | 243 | 6 m 18 s | 17.2 |
| 1344x768 | 5 s | 124 | 9 m 02 s | 25.4 |
| 1344x768 | 10 s | 243 | 28 m 24 s | 81.3 |

**Cost is quadratic in both resolution and length.** 480p 5 s -> 10 s costs 2.6x, not
2x; 1344x768/10 s is 11.7x a 480p/5 s clip. Sweep looks at 864x480 and finish at
1344x768 — you get twelve 480p tries in the time one native render takes.

### SageAttention is a real ~29% win here — but only on the cu130 wheel

`start-headless.js` passes `--use-sage-attention`. Interleaved stock/sage, two rounds, on
an idle machine, 864x480/124f, warmup discarded, fresh seed per run:

| trial | s/it | total |
|---|---|---|
| stock r1 | 5.75 | 134 s |
| **sage r1** | **4.15** | **101 s** |
| stock r2 | 5.76 | 132 s |
| **sage r2** | **4.15** | **100 s** |

**-27.9% s/it, -24.4% wall clock.** Rounds agree to 0.2% / 0.0%, at matched power
(~298 W) and temperature (86-88 C).

Sage holds *higher clocks at the same power* (1215/1050 vs 900/945 MHz) — its int8
attention does more work per watt, which on a 300 W-capped card converts straight into
clock headroom.

Verified genuine, not a silent fallback: the log shows `Using sage attention` with no
`SM89 kernel is not available`, and output quality is unchanged.

This only works because torch cu130 pulled `sageattention 2.2.0+cu130torch2.9.1.post6`,
which ships an **SM89** kernel. The older `2.1.1+cu128torch2.7.0` build has no SM89
kernel: it logs `Using sage attention`, then at the first sampling step reports
`SM89 kernel is not available ... using pytorch attention instead` and silently falls
back, making the flag a no-op. If you ever downgrade torch, expect this speedup to
vanish quietly rather than error.

Sage applies to every model and perturbs attention numerics slightly, so the same seed
gives a near-identical but not bit-identical take. It is enabled on the headless path
only; `start.js` keeps stock attention for interactive work.

### VRAM strategy makes no difference on a 48 GB card

Measured against the same 864x480/124f probe:

| flags | s/it |
|---|---|
| default | 5.75 |
| `--highvram` | 5.80 |
| `--disable-dynamic-vram` | 5.85 |

None of them help. The card peaks around 40 GB of 48 GB with GPU utilization at 100%
and `sw_power_cap` active, i.e. it is compute/power-bound, not memory-bound. Extra VRAM
buys **capability** (no RAM-streaming tax, no OOM at native resolution), not throughput.

Caveat: re-rendering an approved 480p seed at 1344x768 does **not** give the same shot
larger. Resolution changes the latent shape, which reseeds the sampling trajectory, so
you get a related but different take. Only upscaling preserves an approved take.

This card is power-capped: 300 W hard limit (`power.max_limit` is also 300 W), SM clock
throttled to ~780 MHz of 3105 MHz with `sw_power_cap: Active` and thermal *not* active.
A 450 W RTX 4090 runs the same workload roughly 1.35-1.6x faster despite having half the
VRAM. VRAM is not the bottleneck here — the heaviest config peaks around 40 GB of 48 GB.

### Resolution

Canvas rule in code: 768 short edge, area capped at 768x1344, each axis rounded to 32.

| MP | 16:9 |
|---|---|
| 0.4 | 864x480 |
| 0.7 | 1152x640 |
| 0.98 | 1344x768 (template default) |
| 2.0 | 1920x1088 |

### The two checkpoints are mutually exclusive

| Task | Checkpoint | Node |
|---|---|---|
| T2V / I2V / FL2V | `minimax_h3_fl2va_*` | `MiniMaxH3ImageToVideo` |
| Reference-to-video | `minimax_h3_ref2va_*` | `MiniMaxH3ReferenceToVideo` |

This launcher ships the `fl2va` model. Add `ref2va` separately if you need the
reference lane.

"Pruned" is **lossless** — the modulation weights (~40% of params) are replaced with an
equivalent lookup table. The 31.7 GB unpruned variant gives no quality gain over the
19.5 GB pruned one.

### Required models

From [Comfy-Org/MiniMax-H3](https://huggingface.co/Comfy-Org/MiniMax-H3):

```
models/vae/minimax_h3_video_vae_fp16.safetensors          4.9 GB
models/vae/minimax_h3_audio_vae_fp32.safetensors          0.6 GB
models/text_encoders/qwen3vl_32b_minimax_h3_int8_convrot.safetensors   25.3 GB
models/diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors  19.5 GB
```

**Where these actually land.** `install.js` junctions most of `models/` onto Pinokio's
shared drive, so the physical location is not always this folder. On this machine
`vae/` is a junction to `C:\pinokio\drive\drives\peers\<id>\vae` (as are `checkpoints`,
`loras`, `unet`, `controlnet` and others), while `diffusion_models/` and
`text_encoders/` are real directories on the launcher's own drive. Check
`Get-Item models/<dir>` before a large download if drive free space is tight — the two
VAEs go to the shared drive, the encoder and DiT do not.

Do **not** set `HF_HUB_ENABLE_HF_TRANSFER=1` for these. If an hf_transfer download is
interrupted it truncates the `.incomplete` and restarts from zero rather than resuming.
Finalization also sits at full size with no output for several minutes on a ~20 GB file
— that is normal, not a hang.

`fl2va` covers text-to-video and first/last-frame-to-video. For reference-to-video
(`MiniMaxH3ReferenceToVideo`), fetch the matching `ref2va` diffusion model instead.

## Local patches

`patches/` holds source fixes that upstream has not adopted, kept so they survive an
update. After a `git pull` that touches these files, reapply with
`git apply --3way patches/<name>.patch` from the relevant directory.

- `ltx-embeddings-connector-device.patch` — LTX device-mismatch fix in `app/comfy/ldm/lightricks/`.
- `ltxvideo-gemma-single-file-loader.patch` — lets ComfyUI-LTXVideo load a single-file Gemma text encoder.
- `trellis2-modelname-and-clamp.patch` — Trellis2 short model-name alias and a divide-by-zero clamp.

Code carrying these fixes is marked with `CLAUDE-NOTE:` comments explaining why.

## Known gaps

These are optional dependencies that have never been installed in this environment.
Everything else loads cleanly.

- **comfyui-geometrypack** — its isolated pixi environments have not been built, so the
  CGAL-backed nodes fall back or fail to import. Fix by running its `install.py`; this
  downloads several GB across four separate environments.
- **ComfyUI-QwenVL** — `llama_cpp` is absent, so only the GGUF prompt-enhancer submodule
  is unavailable. The rest of the node pack works.
- **cubvh** absent — affected nodes fall back to skimage automatically.
