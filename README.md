# Copilot API setup for Codex and Claude Code

This installer runs [`caozhiyuan/copilot-api`](https://github.com/caozhiyuan/copilot-api)
on localhost and configures isolated copies of Codex CLI and Claude Code to use
models available through your GitHub Copilot account. It supports Linux, macOS,
and WSL on x64 or ARM64.

## Setup

The installer downloads a checksum-verified private Node.js 24 runtime when
needed, installs the three CLIs, opens GitHub's Copilot device login, discovers
the models available to the account, and writes local client configuration:

```bash
bash ./cao-codex-copilot.sh
```

Use `PORT=4242` to choose another local port. Use `MODEL=<model-id>` to require
one model for both clients, or set `CODEX_MODEL` and `CLAUDE_MODEL` separately.
The requested model must be returned by the gateway with an endpoint compatible
with that client.

Rerunning the installer updates the CLIs and preserves the gateway login. It
backs up existing generated gateway and Codex configuration before changing it.

## Run

Start the local gateway in one terminal:

```bash
source "$HOME/.local/share/copilot-codex/env.sh"
start-copilot-api
```

Then, from a project in another terminal, run either client:

```bash
source "$HOME/.local/share/copilot-codex/env.sh"
codex-copilot
# or
claude-copilot
```

The gateway binds only to `127.0.0.1` and is not installed as a background or
boot service. Its generated API key and client configuration are stored with
owner-only permissions under `~/.local/share/copilot-codex`. Keep that directory
private.

Other installed commands:

```bash
copilot-usage  # fetch usage JSON while the gateway is running
copilot-key    # display the local gateway key
```
