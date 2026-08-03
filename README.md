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
