#!/usr/bin/env node
// CLAUDE-NOTE: Thin CLI over ComfyUI's built-in HTTP API, used to drive the headless
// instance started by start-headless.js. Deliberately dependency-free (Node 18+
// global fetch) so it runs from any shell without an npm install step.
//
//   node comfy-api.js status
//   node comfy-api.js nodes [filter]
//   node comfy-api.js run <workflow.api.json> [--out <dir>] [--timeout <seconds>]
//
// Endpoint resolution order: --url > $COMFY_URL > headless.json > http://127.0.0.1:8188
// headless.json is written by start-headless.js, which is why the port does not need
// to be hardcoded anywhere.

const fs = require('fs')
const path = require('path')

const DEFAULT_URL = 'http://127.0.0.1:8188'
const HEADLESS_FILE = path.join(__dirname, 'headless.json')

function resolveUrl(argv) {
  const flag = argv.indexOf('--url')
  if (flag !== -1 && argv[flag + 1]) return argv[flag + 1].replace(/\/$/, '')
  if (process.env.COMFY_URL) return process.env.COMFY_URL.replace(/\/$/, '')
  try {
    const h = JSON.parse(fs.readFileSync(HEADLESS_FILE, 'utf8'))
    if (h.url) return String(h.url).replace(/\/$/, '')
  } catch { /* not running headless, fall through to the default port */ }
  return DEFAULT_URL
}

function flagValue(argv, name, fallback) {
  const i = argv.indexOf(name)
  return i !== -1 && argv[i + 1] ? argv[i + 1] : fallback
}

async function api(url, route, options) {
  const res = await fetch(url + route, options)
  if (!res.ok) {
    const body = await res.text()
    throw new Error(`${options && options.method || 'GET'} ${route} -> ${res.status}\n${body}`)
  }
  return res
}

async function cmdStatus(url) {
  const stats = await (await api(url, '/system_stats')).json()
  const queue = await (await api(url, '/queue')).json()
  const dev = (stats.devices && stats.devices[0]) || {}
  console.log(`endpoint : ${url}`)
  console.log(`comfyui  : ${stats.system && stats.system.comfyui_version}`)
  console.log(`python   : ${stats.system && stats.system.python_version && String(stats.system.python_version).split(' ')[0]}`)
  console.log(`device   : ${dev.name || 'n/a'}`)
  if (dev.vram_total != null) {
    const gb = (n) => (n / 1024 ** 3).toFixed(1)
    console.log(`vram     : ${gb(dev.vram_free)}GB free / ${gb(dev.vram_total)}GB`)
  }
  console.log(`queue    : ${(queue.queue_running || []).length} running, ${(queue.queue_pending || []).length} pending`)
}

async function cmdNodes(url, filter) {
  const info = await (await api(url, '/object_info')).json()
  const names = Object.keys(info).sort()
  const hits = filter
    ? names.filter((n) => n.toLowerCase().includes(filter.toLowerCase()))
    : names
  console.log(`${hits.length} of ${names.length} node classes`)
  for (const n of hits) console.log(n)
}

async function cmdRun(url, workflowPath, outDir, timeoutMs) {
  if (!workflowPath) throw new Error('run requires a workflow JSON path')
  const raw = JSON.parse(fs.readFileSync(workflowPath, 'utf8'))

  // Accept either a bare API-format graph or a {"prompt": {...}} wrapper. A UI-format
  // export (has "nodes"/"links" arrays) will not execute — fail loudly rather than
  // letting ComfyUI reject it with a less obvious error.
  const prompt = raw.prompt || raw
  if (Array.isArray(prompt.nodes) || Array.isArray(prompt.links)) {
    throw new Error(
      `${workflowPath} looks like a UI-format workflow.\n` +
      'Export it via ComfyUI\'s "Workflow > Export (API)" and pass that file instead.'
    )
  }

  const clientId = `comfy-api-${process.pid}-${Date.now()}`
  const submit = await (await api(url, '/prompt', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ prompt, client_id: clientId }),
  })).json()

  if (submit.node_errors && Object.keys(submit.node_errors).length) {
    console.error('node errors:')
    console.error(JSON.stringify(submit.node_errors, null, 2))
    process.exitCode = 1
    return
  }

  const promptId = submit.prompt_id
  console.log(`queued ${promptId}`)

  const deadline = Date.now() + timeoutMs
  let entry
  while (Date.now() < deadline) {
    const hist = await (await api(url, `/history/${promptId}`)).json()
    if (hist[promptId]) {
      const st = hist[promptId].status
      // Only treat it as finished once ComfyUI marks it completed; the history entry
      // appears while the job is still running.
      if (!st || st.completed || st.status_str === 'error') {
        entry = hist[promptId]
        break
      }
    }
    await new Promise((r) => setTimeout(r, 1000))
  }

  if (!entry) throw new Error(`timed out after ${timeoutMs / 1000}s waiting for ${promptId}`)

  if (entry.status && entry.status.status_str === 'error') {
    console.error('execution failed:')
    console.error(JSON.stringify(entry.status.messages, null, 2))
    process.exitCode = 1
    return
  }

  fs.mkdirSync(outDir, { recursive: true })
  let saved = 0
  for (const [nodeId, output] of Object.entries(entry.outputs || {})) {
    for (const kind of ['images', 'gifs', 'videos', 'audio']) {
      for (const item of output[kind] || []) {
        const qs = new URLSearchParams({
          filename: item.filename,
          subfolder: item.subfolder || '',
          type: item.type || 'output',
        })
        const res = await api(url, `/view?${qs}`)
        const buf = Buffer.from(await res.arrayBuffer())
        const dest = path.join(outDir, item.filename)
        fs.writeFileSync(dest, buf)
        console.log(`saved ${dest}  (node ${nodeId})`)
        saved++
      }
    }
  }
  if (!saved) console.log('completed, but the workflow produced no downloadable outputs')
}

async function main() {
  const argv = process.argv.slice(2)
  const cmd = argv[0]
  const url = resolveUrl(argv)

  switch (cmd) {
    case 'status':
      return cmdStatus(url)
    case 'nodes':
      return cmdNodes(url, argv[1] && !argv[1].startsWith('--') ? argv[1] : null)
    case 'run':
      return cmdRun(
        url,
        argv[1] && !argv[1].startsWith('--') ? argv[1] : null,
        flagValue(argv, '--out', path.join(__dirname, 'app', 'output')),
        Number(flagValue(argv, '--timeout', '600')) * 1000
      )
    default:
      console.log('usage: node comfy-api.js <status|nodes|run> [args] [--url <endpoint>]')
      console.log('  status                        show endpoint, version, VRAM, queue depth')
      console.log('  nodes [filter]                list available node classes')
      console.log('  run <wf.api.json> [--out d] [--timeout s]   queue a workflow and save outputs')
      process.exitCode = cmd ? 1 : 0
  }
}

main().catch((e) => {
  console.error(String(e.message || e))
  process.exitCode = 1
})
