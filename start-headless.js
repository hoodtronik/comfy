// CLAUDE-NOTE: Headless sibling of start.js, for agent/API-driven use.
// Differences from start.js, and why:
//   1. Runs on its own {{port}} instead of ComfyUI's default 8188, so it can run
//      side by side with a manual start.js session without a port collision.
//   2. --disable-auto-launch so no browser window is opened.
//   3. Writes the resolved endpoint to headless.json, because an external agent
//      cannot read Pinokio's `local` variables. That file is the contract used by
//      comfy-api.js and is deleted on shutdown by whoever stops the script.
// The Manager-restart handling mirrors start.js — ComfyUI-Manager kills the process
// to reapply dependency installs, and we must resume on the SAME port afterwards.
module.exports = {
  requires: {
    bundle: "ai",
  },
  daemon: true,
  run: [
    // [index 0] Reserve a port up front and stash it. {{port}} re-evaluates on every
    // use, so it must be captured once here — otherwise the restart path below would
    // relaunch on a different port than the one already written to headless.json.
    {
      method: "local.set",
      params: {
        port: "{{port}}"
      }
    },

    // [index 1] Start ComfyUI headless
    {
      "id": "start_comfyui_headless",
      method: "shell.run",
      params: {
        venv: "env",
        env: {
          PYTORCH_ENABLE_MPS_FALLBACK: "1",
          TOKENIZERS_PARALLELISM: "false",
          // CLAUDE-NOTE: Required for headless. Several custom nodes (rgthree-comfy is
          // the first) print emoji at import time. With no attached console, Windows
          // Python encodes stdout as cp1252 and the UnicodeEncodeError propagates out
          // of logging, aborting startup before the server binds. Forcing utf-8 here
          // is what makes an unattended/redirected launch survive node imports.
          PYTHONIOENCODING: "utf-8"
        },
        path: "app",
        // CLAUDE-NOTE: --use-sage-attention is measured, not assumed: on this RTX 6000 Ada
        // (sm_89) it took MiniMax H3 from 5.75 s/it to 4.07 s/it (-29%) at 864x480/124f,
        // with no quality regression and no fallback in the log. It only works because the
        // cu130 upgrade pulled sageattention 2.2.0+cu130torch2.9.1, which ships an SM89
        // kernel; older cu128 builds log "SM89 kernel is not available" and silently fall
        // back to pytorch attention, making the flag a no-op.
        // Sage applies to every model, not just H3, and perturbs attention numerics
        // slightly — same seed gives a near-identical but not bit-identical take. It is set
        // here (agent/throughput path) and deliberately NOT in start.js, so interactive work
        // keeps stock attention. Drop the flag if a model ever looks wrong under it.
        message: [
          "{{platform === 'win32' && gpu === 'amd' ? 'python main.py --directml --port ' + local.port + ' --disable-auto-launch' : 'python main.py --port ' + local.port + ' --disable-auto-launch --use-sage-attention'}}"
        ],
        on: [{
          "event": "/To see the GUI go to: +(http:\/\/[a-zA-Z0-9.]+:[0-9]+)/i",
          "done": true
        }, {
          // kill: true ensures ComfyUI is fully terminated before we jump back to restart
          // after manager installs custom nodes
          "event": "/\\[ComfyUI-Manager\\] Restarting to reapply dependency installation/",
          "kill": true
        }, {
          "event": "/errno/i",
          "break": false
        }, {
          "event": "/error:/i",
          "break": false
        }]
      }
    },

    // [index 2] Single conditional jump — routes to set_url on normal startup, or to
    // manager_restart when Manager killed ComfyUI for dep installation.
    // input.event[1] contains the URL on normal startup; absent on Manager restart.
    // Pass the URL through jump params since jump resets input.
    {
      method: "jump",
      params: {
        id: "{{input.event && input.event[1] ? 'set_url' : 'manager_restart'}}",
        params: {
          url: "{{input.event && input.event[1] ? input.event[1] : ''}}"
        }
      }
    },

    // [index 3] Manager restart path
    {
      "id": "manager_restart",
      method: "notify",
      params: {
        html: "<b>✅ ComfyUI Manager installed new dependencies</b><br>Restarting headless ComfyUI to apply them — this will take a moment.",
        type: "info"
      }
    },
    {
      method: "jump",
      params: {
        id: "start_comfyui_headless"
      }
    },

    // [index 5] Normal startup — record the URL captured from the shell event
    {
      "id": "set_url",
      method: "local.set",
      params: {
        url: "{{input.url}}"
      }
    },

    // [index 6] Publish the endpoint for external API clients (see comfy-api.js).
    {
      method: "fs.write",
      params: {
        path: "headless.json",
        json: {
          url: "{{local.url}}",
          port: "{{local.port}}"
        }
      }
    },

    {
      method: "notify",
      params: {
        html: "<b>🤖 Headless ComfyUI running</b><br>{{local.url}}",
        type: "info"
      }
    }
  ]
}
