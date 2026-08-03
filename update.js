module.exports = {
  run: [{
    method: "shell.run",
    params: {
      // CLAUDE-NOTE: --autostash so a customized launcher still updates. This repo
      // carries local launcher changes (start-headless.js, comfy-api.js, the
      // captured-URL fix in start.js); a bare `git pull` aborts outright if any of
      // them are uncommitted at update time.
      message: "git pull --autostash"
    }
  }, {
    method: "shell.run",
    params: {
      path: "app",
      // CLAUDE-NOTE: The ComfyUI checkout carries local source fixes upstream has not
      // adopted (see patches/ and the CLAUDE-NOTE markers in app/). A bare `git pull`
      // refuses to run with those in the working tree, which is what made this button
      // fail. --autostash stashes them, pulls, and restores them automatically.
      // If restoring conflicts, git leaves the stash intact and reports it — recover
      // with `git stash pop` or reapply from patches/ (see README "Local patches").
      message: "git pull --autostash"
    }
  }, {
    method: "shell.run",
    params: {
      message: [
        "git clone https://github.com/comfyanonymous/ComfyUI_examples"
      ],
      path: "app/user/default/workflows"
    }
  }, {
    method: "shell.run",
    params: {
      message: [
        "git pull"
      ],
      path: "app/user/default/workflows/ComfyUI_examples"
    }
  }, {
    method: "shell.run",
    params: {
      message: [
        "git clone https://github.com/cocktailpeanut/comfy_json_workflow"
      ],
      path: "app/user/default/workflows"
    }
  }, {
    method: "shell.run",
    params: {
      message: [
        "git pull"
      ],
      path: "app/user/default/workflows/comfy_json_workflow"
    }
  }, {
    method: "shell.run",
    params: {
      path: "app",
      venv: "env",
      message: [
        "uv pip install -r requirements.txt"
      ],
    }
  }]
}
