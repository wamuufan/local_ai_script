# localai.sh

> **Local AI Environment Manager** — A single-file Bash script for spinning up isolated, modular AI development and runtime environments using [Podman](https://podman.io/) and [Distrobox](https://distrobox.it/).

[![License: BSD 2-Clause](https://img.shields.io/badge/License-BSD%202--Clause-blue.svg)](https://opensource.org/licenses/BSD-2-Clause)
![Shell: Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=white)
![Requires: Podman](https://img.shields.io/badge/Requires-Podman-892CA0?logo=podman&logoColor=white)

---

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Command Reference](#command-reference)
  - [doctor](#doctor)
  - [container new](#container-new)
  - [container list](#container-list)
  - [container rm](#container-rm)
  - [install](#install)
  - [start](#start)
  - [stop](#stop)
  - [shell](#shell)
- [File System Layout](#file-system-layout)
- [Data Persistence](#data-persistence)
- [Supported Tools](#supported-tools)
  - [Ollama](#ollama)
  - [ComfyUI](#comfyui)
- [Adding New Tools](#adding-new-tools)
- [License](#license)

---

## Overview

`localai.sh` is a **single-file** Bash administration script that lets you create fully isolated AI workspaces on your local machine. Each workspace is a [Distrobox](https://distrobox.it/) container built on **Ubuntu 26.04** with its own home directory, keeping your host system clean and your AI projects reproducible.

All containers are NVIDIA-passthrough enabled out of the box. Model files, outputs, logs, and virtual environments are stored in a dedicated directory that **survives container deletion**.

---

## Features

- 🗂️ **Single-file architecture** — everything lives in `localai.sh`, no external scripts
- 🔒 **Isolated home directories** — each container gets its own `~/.local/containers/<name>/`
- 🔌 **Modular tool system** — add new AI tools by implementing 3 functions
- 🔁 **Idempotent operations** — safe to re-run install commands multiple times
- 🚦 **PID-based service control** — start/stop with double-start prevention and graceful shutdown
- 🎨 **Coloured terminal output** — INFO, SUCCESS, WARN, ERROR levels with TTY detection
- 🛡️ **Strict error handling** — `set -euo pipefail` throughout
- 💾 **Persistent data** — container data is **never** deleted by `container rm`
- 🖥️ **NVIDIA GPU passthrough** — `--nvidia` flag applied at container creation

---

## Requirements

### Required

| Dependency | Purpose | Install |
|---|---|---|
| `podman` | Container runtime | `sudo apt install podman` |
| `distrobox` | Container management | [distrobox.it](https://distrobox.it/#installation) |
| `bash` ≥ 4.0 | Script runtime | Pre-installed on most Linux distros |
| `curl` | Downloading installers | `sudo apt install curl` |
| `git` | Cloning repositories | `sudo apt install git` |

### Optional

| Dependency | Purpose |
|---|---|
| `nvidia-smi` | GPU passthrough & CUDA detection |
| `nvcc` | CUDA compilation inside containers |

> Run `localai.sh doctor` to automatically check all dependencies.

---

## Installation

```bash
# 1. Clone or download the script
git clone https://github.com/wamuufan/localai.sh.git
cd localai.sh

# 2. Make it executable
chmod +x localai.sh

# 3. (Optional) Put it on your PATH
sudo ln -s "$(pwd)/localai.sh" /usr/local/bin/localai.sh

# 4. Verify your system is ready
./localai.sh doctor
```

---

## Quick Start

```bash
# Check dependencies
localai.sh doctor

# Create an isolated container for Ollama
localai.sh container new ollama-box

# Install Ollama inside it
localai.sh install ollama-box ollama

# Start the Ollama API server in the background
localai.sh start ollama-box ollama

# Enter the container and pull a model
localai.sh shell ollama-box
# Inside the container:
#   ollama pull llama3.2
#   ollama run llama3.2

# Stop the server when done
localai.sh stop ollama-box ollama
```

```bash
# Create a separate container for ComfyUI
localai.sh container new image-gen

# Install ComfyUI (clones repo, creates venv, installs PyTorch)
localai.sh install image-gen comfyui

# Start the web UI on http://localhost:8188
localai.sh start image-gen comfyui
```

---

## Command Reference

### `doctor`

Checks all required and optional host dependencies and reports their status.

```bash
localai.sh doctor
```

**Checks performed:**
- `podman`, `distrobox`, `git`, `curl` (required)
- `nvidia-smi`, `nvcc` (optional, for GPU workloads)
- Base directory `~/.local/containers/`
- Total number of existing containers

---

### `container new`

Creates a new Ubuntu 26.04 Distrobox container with an isolated home directory and NVIDIA passthrough.

```bash
localai.sh container new <name>
```

**What it does:**
1. Creates `~/.local/containers/<name>/` on the host
2. Runs `distrobox create --home ~/.local/containers/<name>/ --nvidia`
3. Bootstraps the container with base packages: `python3`, `git`, `curl`, `build-essential`, etc.

**Example:**
```bash
localai.sh container new my-ai-lab
```

---

### `container list`

Lists all Distrobox containers alongside their data-directory status.

```bash
localai.sh container list
```

**Output columns:** `NAME`, `STATUS`, `DATA DIR` (exists/missing), `IMAGE`

---

### `container rm`

Removes a container via `distrobox rm --force`. **The data directory is never touched.**

```bash
localai.sh container rm <name>
```

> ⚠️ You will be prompted for confirmation before removal.

To restore a removed container while reusing existing data:
```bash
localai.sh container new <name>   # data in ~/.local/containers/<name>/ is reused automatically
```

---

### `install`

Installs a supported AI tool inside an existing container. All install functions are **idempotent** — re-running them is safe.

```bash
localai.sh install <container> <tool>
```

**Supported tools:** `ollama`, `comfyui`

**Examples:**
```bash
localai.sh install my-ai-lab ollama
localai.sh install image-gen comfyui
```

---

### `start`

Starts a tool's service in the **background** inside the container. Uses PID files to prevent double-starting.

```bash
localai.sh start <container> <tool>
```

**Examples:**
```bash
localai.sh start my-ai-lab ollama    # API available at http://localhost:11434
localai.sh start image-gen comfyui   # Web UI available at http://localhost:8188
```

Logs are written to `~/.local/containers/<name>/.run/<tool>.log`.

---

### `stop`

Gracefully stops a running service using SIGTERM, then SIGKILL if it does not exit within the timeout.

```bash
localai.sh stop <container> <tool>
```

| Tool | Graceful timeout |
|---|---|
| `ollama` | 10 seconds |
| `comfyui` | 15 seconds |

---

### `shell`

Opens an interactive shell inside the specified container via `distrobox enter`.

```bash
localai.sh shell <container>
```

Type `exit` to return to the host shell.

---

## File System Layout

```
~/.local/containers/
├── .logs/                          # Host-side log directory
│
├── <container-name>/               # Isolated home directory (persists after container removal)
│   ├── .run/
│   │   ├── ollama.pid              # PID file for the Ollama service
│   │   ├── comfyui.pid             # PID file for the ComfyUI service
│   │   ├── ollama.log              # Ollama runtime logs
│   │   └── comfyui.log             # ComfyUI runtime logs
│   │
│   ├── .ollama/
│   │   ├── models/                 # Downloaded Ollama models (persistent)
│   │   └── ollama.env              # Runtime environment variables
│   │
│   ├── comfyui/
│   │   ├── .venv/                  # Python virtual environment
│   │   ├── models/
│   │   │   ├── checkpoints/        # Stable Diffusion checkpoints
│   │   │   ├── loras/
│   │   │   ├── vae/
│   │   │   ├── controlnet/
│   │   │   └── clip/
│   │   ├── output/                 # Generated images
│   │   ├── input/                  # Input images
│   │   └── custom_nodes/           # ComfyUI extensions
│   └── .comfyui.env                # Runtime environment variables
```

---

## Data Persistence

> **Your data is safe.** `localai.sh container rm` only runs `distrobox rm` — it never touches `~/.local/containers/<name>/`.

This means:
- Downloaded AI models survive container deletion
- Virtual environments and installed packages survive container deletion
- You can recreate a container and instantly resume where you left off

---

## Supported Tools

### Ollama

[Ollama](https://ollama.com/) is a local LLM runtime that supports models like Llama 3, Mistral, Phi, Gemma and many more.

| Detail | Value |
|---|---|
| Installer | Official `https://ollama.com/install.sh` |
| API port | `11434` |
| Models dir | `~/.local/containers/<name>/.ollama/models/` |
| Logs | `~/.local/containers/<name>/.run/ollama.log` |

**Common commands inside the container:**
```bash
ollama pull llama3.2
ollama pull mistral
ollama run llama3.2
ollama list
```

---

### ComfyUI

[ComfyUI](https://github.com/comfyanonymous/ComfyUI) is a node-based stable diffusion UI supporting SDXL, Flux, ControlNet, LoRA, and more.

| Detail | Value |
|---|---|
| Source | GitHub `comfyanonymous/ComfyUI` |
| Web UI port | `8188` |
| PyTorch | Auto-detected: CUDA (if NVIDIA GPU) or CPU-only |
| Models dir | `~/.local/containers/<name>/comfyui/models/checkpoints/` |
| Logs | `~/.local/containers/<name>/.run/comfyui.log` |

**Drop your `.safetensors` or `.ckpt` checkpoint files into:**
```
~/.local/containers/<name>/comfyui/models/checkpoints/
```

---

## Adding New Tools

The tool system is intentionally modular. To add support for a new tool:

**Step 1 — Implement three functions:**

```bash
install_mytool() {
    local container="$1"
    local home_dir="${BASE_DIR}/${container}"

    log_header "Installing mytool → ${container}"
    # ... idempotent installation logic ...
    log_success "mytool installed."
}

start_mytool() {
    local container="$1"
    local home_dir="${BASE_DIR}/${container}"
    local pid_f;  pid_f="$(pid_file "${container}" "mytool")"
    local log_f="${home_dir}/.run/mytool.log"

    mkdir -p "${home_dir}/.run"

    # Double-start guard & stale PID check inside container
    check_and_clean_pid "${container}" "${pid_f}" "mytool" || return 0

    distrobox enter "${container}" -- bash -c "
        nohup mytool-server > '${log_f}' 2>&1 &
        echo \$! > '${pid_f}'
    "
    log_success "mytool started."
}

stop_mytool() {
    stop_service_in_container "$1" "mytool" 5
}
```

**Step 2 — Register the tool name:**

```bash
readonly SUPPORTED_TOOLS=("ollama" "comfyui" "mytool")
```

That's it. Argument routing, validation, and error messages are handled automatically.

---

## License

Copyright (c) 2026, wamuufan.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
