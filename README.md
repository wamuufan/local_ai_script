# localai.sh

> **Local AI Environment Manager** — A modular Bash tool suite for spinning up isolated, modular AI development and runtime environments using [Podman](https://podman.io/) and [Distrobox](https://distrobox.it/).

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
  - [Global Options](#global-options)
  - [doctor](#doctor)
  - [container new](#container-new)
  - [container list](#container-list)
  - [container rm](#container-rm)
  - [install](#install)
  - [uninstall](#uninstall)
  - [update](#update)
  - [start](#start)
  - [stop](#stop)
  - [restart](#restart)
  - [status](#status)
  - [logs](#logs)
  - [open](#open)
  - [shell](#shell)
  - [model](#model)
  - [transcribe](#transcribe)
  - [memory](#memory)
- [Configuration & Memory Profiles](#configuration--memory-profiles)
- [File System Layout](#file-system-layout)
- [Data Persistence](#data-persistence)
- [Supported Tools](#supported-tools)
  - [Ollama](#ollama)
  - [ComfyUI](#comfyui)
  - [Open WebUI](#open-webui)
  - [IOPaint](#iopaint)
  - [Whisper (Speaches / faster-whisper)](#whisper-speaches--faster-whisper)
  - [Native Viewer (WebKitGTK)](#native-viewer-webkitgtk)
- [Adding New Tools](#adding-new-tools)
- [Security Notes](#security-notes)
- [License](#license)

---

## Overview

`localai.sh` is a modular Bash environment management tool that lets you create fully isolated AI workspaces on your local machine. Each workspace is a [Distrobox](https://distrobox.it/) container built on **Ubuntu 26.04** with its own home directory, keeping your host system clean and your AI projects reproducible.

All containers are NVIDIA-passthrough enabled out of the box. Model files, outputs, logs, and virtual environments are stored in a dedicated directory that **survives container deletion**.

---

## Features

- 🗂️ **Modular architecture** — clean separation of core dispatcher, container managers, and tool modules in `bin/`
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
localai.sh install ollama-box:ollama

# Start the Ollama API server in the background
localai.sh start ollama-box:ollama

# Enter the container and pull a model
localai.sh shell ollama-box
# Inside the container:
#   ollama pull llama3.2
#   ollama run llama3.2

# Stop the server when done
localai.sh stop ollama-box:ollama
```

```bash
# Create a separate container for ComfyUI
localai.sh container new image-gen

# Install ComfyUI (clones repo, creates venv, installs PyTorch)
localai.sh install image-gen:comfyui

# Start the web UI on http://localhost:8188
localai.sh start image-gen:comfyui
```

---

## Command Reference

### Global Options

The following flags can precede any command:

- `-v`, `--verbose` : Enable detailed debug output and trace execution.
- `-c <file>`, `--config <file>` : Specify a custom configuration file path (defaults to auto-detecting `localai.conf` or `<container>.conf`).

```bash
localai.sh -v status
localai.sh -c /path/to/custom.conf start my-ai-lab:all
```

---

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
localai.sh install <container>:<tool1,tool2,...> [<container2>:<tool3,...>]
```

> ℹ️ Note: The `all` target is not supported for `install`. Explicit tool names must be specified.

**Supported tools:** `ollama`, `comfyui`, `openwebui`, `iopaint`, `whisper`, `viewer`

**Examples:**
```bash
localai.sh install my-ai-lab:ollama
localai.sh install image-gen:comfyui
localai.sh install speech:whisper
```

---

### `uninstall`

Uninstalls installed tool(s) and their virtual/conda environments from a container while keeping persistent models. Supports the `<container>:all` shortcut to uninstall all installed tools (including `viewer`).

```bash
localai.sh uninstall <container>:<tool1,tool2,...|all> [<container2>:<tool3,...>]
```

**Examples:**
```bash
localai.sh uninstall my-ai-lab:openwebui
localai.sh uninstall speech:whisper
localai.sh uninstall my-ai-lab:all          # Uninstalls all tools installed in the container
```

---

### `update`

Updates installed tool(s) to their latest release or commit inside the container. Supports the `<container>:all` shortcut to update all installed services.

```bash
localai.sh update <container>:<tool1,tool2,...|all> [<container2>:<tool3,...>]
```

**What it does per tool:**
- **Ollama**: Re-executes the official installer to update the binary.
- **ComfyUI**: Performs `git pull --ff-only` and upgrades requirements via `pip install -r requirements.txt --upgrade`.
- **Open WebUI**: Runs `pip install --upgrade open-webui` inside its conda environment.
- **IOPaint**: Runs `pip install --upgrade iopaint` inside its conda environment.
- **Whisper**: Upgrades pip tooling, dependencies, and `speaches`.

**Examples:**
```bash
localai.sh update my-ai-lab:ollama
localai.sh update image-gen:comfyui
localai.sh update my-ai-lab:ollama,openwebui
localai.sh update my-ai-lab:all
```

---

### `start`

Starts a tool's service in the **background** inside the container. Uses PID files to prevent double-starting. Supports the `<container>:all` shortcut to start all installed tools.

```bash
localai.sh start <container>:<tool1,tool2,...|all> [<container2>:<tool3,...>]
```

**Examples:**
```bash
localai.sh start my-ai-lab:ollama    # API available at http://localhost:11434
localai.sh start image-gen:comfyui   # Web UI available at http://localhost:8188
localai.sh start speech:whisper      # STT server available at http://localhost:8083
localai.sh start my-ai-lab:all       # Starts all installed tools in container
```

Logs are written to `log/<container>/<tool>.log`.

---

### `stop`

Gracefully stops running service(s) using SIGTERM, then SIGKILL if it does not exit within the timeout. Supports the `<container>:all` shortcut to stop all installed tools.

```bash
localai.sh stop <container>:<tool1,tool2,...|all> [<container2>:<tool3,...>]
```

| Tool | Graceful timeout |
|---|---|
| `ollama` | 10 seconds |
| `comfyui` | 15 seconds |
| `openwebui` | 15 seconds |
| `iopaint` | 15 seconds |
| `whisper` | 15 seconds |

**Examples:**
```bash
localai.sh stop my-ai-lab:ollama
localai.sh stop my-ai-lab:all
```

---

### `restart`

Restarts service(s) by executing a graceful stop followed by a start. Supports the `<container>:all` shortcut.

```bash
localai.sh restart <container>:<tool1,tool2,...|all> [<container2>:<tool3,...>]
```

**Examples:**
```bash
localai.sh restart my-ai-lab:ollama
localai.sh restart my-ai-lab:all
```

---

### `status`

Displays the runtime status (running PID, listening ports, health, memory usage) of services. If invoked without arguments, prints a tree of all containers and tools. Supports `<container>:all`.

```bash
# Tree view of all containers and services:
localai.sh status

# Target specific container tools or all:
localai.sh status <container>:<tool1,tool2,...|all> [<container2>:<tool3,...>]
```

**Examples:**
```bash
localai.sh status
localai.sh status my-ai-lab:ollama
localai.sh status my-ai-lab:all
```

---

### `logs`

Follows or views stdout/stderr runtime logs for services. Supports the `<container>:all` shortcut to stream logs from all installed tools in the container simultaneously.

```bash
localai.sh logs [-n <lines>] [--no-follow] <container>:<tool1,tool2,...|all> [<container2>:<tool3,...>]
```

**Flags:**
- `-n <lines>`, `--lines <lines>`: Number of lines to show (default: `100`).
- `--no-follow`, `--no-tail`: View the last lines without streaming live updates (`tail -f`).

**Examples:**
```bash
localai.sh logs my-ai-lab:ollama
localai.sh logs -n 50 --no-follow image-gen:comfyui
localai.sh logs speech:whisper
localai.sh logs my-ai-lab:all
```

---

### `open`

Opens a tool's user interface inside an **ultra-lightweight native WebKitGTK window** (~45 MB RAM) directly from the container.

- **No address bar**, navigation buttons, or browser bloat.
- **No shortcut hijacking**: `Ctrl+S` passes directly to the web app (e.g. saving ComfyUI workflows without triggering browser "Save Page As" dialogs).
- **Auto-starts service**: If the tool is installed but stopped, `localai.sh open` starts it first.
- **Auto-installs viewer**: If the viewer component is not yet present in the container, it installs it automatically.

```bash
localai.sh open <container>:<tool>
# or custom port / URL:
localai.sh open <container> <port|url>
```

**Examples:**
```bash
localai.sh open image-gen:comfyui    # Opens ComfyUI at http://localhost:8188
localai.sh open my-ai-lab:openwebui  # Opens Open WebUI at http://localhost:8080
localai.sh open image-gen:iopaint    # Opens IOPaint at http://localhost:8082
localai.sh open image-gen 8188       # Opens custom port on localhost
```

---

### `shell`

Opens an interactive shell inside the specified container via `distrobox enter`.

```bash
localai.sh shell <container>
```

Type `exit` to return to the host shell.

---

### `model`

Manages models for supported tools (such as Ollama and Whisper).

- **Pulling a model:**
  ```bash
  localai.sh model pull <container>:<tool> <model_name>
  ```
- **Listing models:**
  ```bash
  localai.sh model list <container>:<tool>
  ```

**Examples:**
```bash
# Pull and list models with Ollama:
localai.sh model pull my-ai-lab:ollama llama3.2
localai.sh model list my-ai-lab:ollama

# Download a model for Whisper (from HuggingFace Hub) and set as default:
localai.sh model pull speech:whisper Systran/faster-whisper-large-v3
localai.sh model pull speech:whisper Systran/faster-whisper-small

# List downloaded Whisper models in a container:
localai.sh model list speech:whisper
```

---

### `transcribe`

Transcribes audio files into text using the Whisper (Speaches) service inside a container. If the Whisper service is currently stopped, it starts it temporarily for the transcription request.

```bash
localai.sh transcribe <container>:whisper <audio_file> [--lang <lang>] [--format <format>]
```

**Options:**
- `--lang <lang>` (or `--language <lang>`): Spoken language code (e.g., `en`, `tr`, `de`, `fr`). Defaults to auto-detection.
- `--format <format>`: Output response format (e.g., `json`, `text`, `srt`, `vtt`). Default: `json`. The transcription output is written to `<audio_file>.<format>`.

**Examples:**
```bash
# Basic transcription (saves output to speech.wav.json):
localai.sh transcribe speech:whisper /path/to/speech.wav

# Specify Turkish language and text output (saves to interview.mp3.text):
localai.sh transcribe speech:whisper ~/interview.mp3 --lang tr --format text

# Generate SRT subtitles:
localai.sh transcribe speech:whisper podcast.m4a --format srt
```

---

### `memory`

Monitors and aggressively manages RAM, Swap, NVIDIA GPU VRAM, and AI process allocations.

```bash
# Check host & container memory usage and active profile
localai.sh memory status [<container>]

# Reclaim VRAM, evict idle models, purge shared memory, and sync caches
localai.sh memory clean [<container>] [--all|--vram|--ram|--cache]
```

**Actions performed by `memory clean`:**
- **VRAM Eviction**: Dispatches API eviction calls (`keep_alive: 0`) to running Ollama instances and triggers model unload in ComfyUI.
- **Shared Memory Cleanup**: Removes stale `/dev/shm` IPC handles (`torch_*`, `cuda_*`, `sem.*`).
- **Filesystem & Page Cache Sync**: Executes system `sync` and flushes cache if permitted.

---

## File System Layout

```
~/.local/containers/
├── <container-name>/               # Isolated home directory (persists after container removal)
│   ├── .run/                       # Runtime process PID tracking
│   │   ├── ollama.pid              # PID file for the Ollama service
│   │   ├── comfyui.pid             # PID file for the ComfyUI service
│   │   ├── openwebui.pid           # PID file for Open WebUI
│   │   ├── iopaint.pid             # PID file for IOPaint
│   │   └── whisper.pid             # PID file for Whisper (Speaches)
│   │
│   ├── .ollama/
│   │   └── models/                 # Downloaded Ollama models (persistent)
│   │
│   ├── .openwebui/
│   │   ├── conda/                  # Miniforge Python environment
│   │   └── data/                   # User data and configurations
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
│   │
│   ├── iopaint/
│   │   ├── conda/                  # Miniforge Python environment
│   │   └── models/                 # Downloaded inpainting models
│   │
│   ├── whisper/
│   │   ├── conda/                  # Miniforge Python environment
│   │   └── models/                 # Downloaded HuggingFace STT models
│   │
│   ├── .localai.env                # Base container environment configuration
│   └── .<tool>.user.env            # User/config overrides per tool
│
<project-root>/
└── log/
    ├── <container>/                # Per-container service logs
    │   ├── ollama.log
    │   ├── comfyui.log
    │   ├── openwebui.log
    │   ├── iopaint.log
    │   └── whisper.log
    └── localai_YYYY-MM-DD.jsonl    # Host audit & structured execution logs
```

---

## Data Persistence

> **Your data is safe.** `localai.sh container rm` only runs `distrobox rm` — it never touches `~/.local/containers/<name>/` unless the `-p` / `--purge` flag is provided.

This means:
- Downloaded AI models survive container deletion
- Virtual environments and installed packages survive container deletion
- You can recreate a container and instantly resume where you left off

> **Note on Moving Directories:** Python virtual environments (`.venv`) store absolute paths internally. If you move `~/.local/containers` to a different disk or symlink it elsewhere, activate the virtualenv and update paths or reinstall the tool environment.

---

## Supported Tools

### Ollama

[Ollama](https://ollama.com/) is a local LLM runtime that supports models like Llama 3, Mistral, Phi, Gemma and many more.

| Detail | Value |
|---|---|
| Installer | Official `https://ollama.com/install.sh` |
| API port | `11434` |
| Models dir | `~/.local/containers/<name>/.ollama/models/` |
| Logs | `log/<container>/ollama.log` |

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
| Logs | `log/<container>/comfyui.log` |

**Drop your `.safetensors` or `.ckpt` checkpoint files into:**
```
~/.local/containers/<name>/comfyui/models/checkpoints/
```

---

### Open WebUI

[Open WebUI](https://openwebui.com/) is an extensible, feature-rich, and user-friendly frontend for local LLMs (like Ollama).

| Detail | Value |
|---|---|
| Source | Official PyPi `open-webui` |
| Web UI port | `8080` |
| Environment | Dedicated Miniforge Python 3.11 |
| Data dir | `~/.local/containers/<name>/.openwebui/data/` |
| Logs | `log/<container>/openwebui.log` |

**To run Ollama and Open WebUI together:**
```bash
localai.sh start <container>:ollama,openwebui
```

---

### IOPaint

[IOPaint](https://github.com/Sanster/IOPaint) is a free and open-source image inpainting & outpainting tool powered by SOTA AI models (such as LaMa, MAT, etc.).

| Detail | Value |
|---|---|
| Source | Official PyPI `iopaint` |
| Web UI port | `8082` |
| Environment | Dedicated Miniforge Python 3.10 |
| PyTorch | Auto-detected: CUDA (if NVIDIA GPU) or CPU-only |
| Models dir | `~/.local/containers/<name>/iopaint/models/` |
| Logs | `log/<container>/iopaint.log` |

**To install and start IOPaint:**
```bash
localai.sh install <container>:iopaint
localai.sh start <container>:iopaint
# Open http://localhost:8082 in your browser
```

---

### Whisper (Speaches / faster-whisper)

[Speaches](https://github.com/speaches-ai/speaches) is an OpenAI-compatible Speech-to-Text (STT) server powered by `faster-whisper` and PyTorch.

| Detail | Value |
|---|---|
| Source | PyPI `speaches` (`faster-whisper`) |
| API port | `8083` |
| Environment | Dedicated Miniforge Python 3.12 |
| PyTorch | Auto-detected: CUDA (if NVIDIA GPU) or CPU-only |
| App & Models dir | `~/.local/containers/<name>/whisper` (`~/.local/containers/<name>/whisper/models/`) |
| Logs | `log/<container>/whisper.log` |

**To install and run Whisper:**
```bash
# 1. Install Whisper in container:
localai.sh install speech:whisper

# 2. Download a model from Hugging Face:
localai.sh model pull speech:whisper Systran/faster-whisper-large-v3

# 3. List downloaded models:
localai.sh model list speech:whisper

# 4. Start the STT server:
localai.sh start speech:whisper

# 5. Transcribe an audio file directly:
localai.sh transcribe speech:whisper sample.wav --lang en --format json
```

---

### Native Viewer (WebKitGTK)

An ultra-lightweight, dedicated native app window engine based on Linux's official WebKitGTK stack (`gir1.2-webkit2-4.1` / `python3-gi`). Designed specifically to view local AI user interfaces without using the host desktop browser.

| Detail | Value |
|---|---|
| Engine | WebKitGTK (Ubuntu official system package) |
| Memory (RAM) | **~45 - 65 MB** |
| Address bar / Toolbars | **None** (Clean, distraction-free app window) |
| Shortcuts | `Ctrl+S` preserved for AI app workflows; `F5`/`Ctrl+R` for reload; `F11` for fullscreen |
| Launcher path | `~/.local/containers/<name>/.local/bin/localai-viewer` |

**To install and run:**
```bash
# Explicit installation:
localai.sh install <container>:viewer

# Or simply open any tool (viewer installs automatically if missing):
localai.sh open image-gen:comfyui
localai.sh open my-ai-lab:openwebui
```

---

## Configuration & Memory Strategies

`localai.sh` provides two disabled configuration templates out of the box:
- `localai.dynamic.conf.disabled`: Dynamic strategy-based configuration (`MEMORY_STRATEGY=aggressive_release | balanced_caching | high_performance_pinned`). Automatically tunes VRAM unloading, smart memory, PyTorch CUDA fragmentation guards, and post-stop reclamation.
- `localai.static.conf.disabled`: Direct static configuration with all aggressive memory-saving parameters pre-configured and explained line-by-line (`keep_alive=0`, `num_parallel=1`, `--disable-smart-memory`, `PYTORCH_CUDA_ALLOC_CONF`, TCMalloc).

> ℹ️ **NOTE**: Files ending with `.disabled` are strictly ignored by the script.

### Memory Strategies Explained

| Strategy | VRAM & RAM Management Behavior | Recommended For |
| :--- | :--- | :--- |
| `aggressive_release` | Immediate VRAM model offloading (`keep_alive=0`, `--disable-smart-memory`), single concurrent context slot, PyTorch allocator anti-fragmentation guards, TCMalloc preloaded. | GPUs ≤ 12GB VRAM or systems ≤ 32GB RAM |
| `balanced_caching` | 5-minute model warm retention in Ollama, ComfyUI smart memory caching active for fast consecutive generations. | Systems with 16GB VRAM & 32GB–64GB RAM |
| `high_performance_pinned` | Models permanently pinned in VRAM (`keep_alive=-1`), up to 4 parallel contexts, `--highvram` enabled in ComfyUI. | Dedicated AI workstations (24GB+ VRAM & 64GB+ RAM) |

### Activating a Configuration

To enable a configuration mode, remove the `.disabled` suffix (or copy to `localai.conf`):

```bash
# Option 1: Activate dynamic memory strategy configuration (Recommended)
cp localai.dynamic.conf.disabled localai.conf

# Option 2: Activate direct static configuration
cp localai.static.conf.disabled localai.conf
```

---

## Adding New Tools

The tool system is completely modular and self-discovering. To add a new tool:

Simply create a new script file in `bin/tools/<mytool>.sh`. All `.sh` files placed in `bin/tools/` are sourced automatically by `localai.sh`, and tool names are dynamically discovered by `get_supported_tools()`. **There is no need to manually edit or maintain a `readonly SUPPORTED_TOOLS=(...)` array.**

Inside `bin/tools/<mytool>.sh`, implement the following standard functions:

```bash
#!/usr/bin/env bash
set -euo pipefail

# 1. Check if tool is installed
is_installed_mytool() {
    local container="$1"
    local home_dir="${BASE_DIR}/${container}"
    [[ -d "${home_dir}/mytool" ]]
}

# 2. Install tool (idempotent)
install_mytool() {
    local container="$1"
    local home_dir="${BASE_DIR}/${container}"

    log_header "Installing mytool → ${container}"
    ensure_base_packages "${container}" git curl procps

    # Installation logic inside container...
    log_success "mytool installed."
}

# 3. Start service
start_mytool() {
    local container="$1"
    local home_dir="${BASE_DIR}/${container}"
    local pid_f; pid_f="$(pid_file "${container}" "mytool")"
    local log_f="${LOG_DIR}/${container}/mytool.log"

    local port="8085"
    local start_script="
        set -e
        nohup mytool-server --port ${port} >> '${log_f}' 2>&1 &
        echo \"\$!\" > '${pid_f}'
    "

    # Uses the unified start_service_in_container helper with PID checks & port polling:
    start_service_in_container "${container}" "mytool" "${port}" "mytool-server" "${start_script}" 30 "http://localhost:${port}"
}

# 4. Stop service
stop_mytool() {
    stop_service_in_container "$1" "mytool" 15
}

# 5. Update tool (optional)
update_mytool() {
    local container="$1"
    log_header "Updating mytool → ${container}"
    # Update logic...
    log_success "mytool updated."
}

# 6. Uninstall tool
uninstall_mytool() {
    local container="$1"
    local home_dir="${BASE_DIR}/${container}"

    log_header "Uninstalling mytool ← ${container}"
    stop_mytool "${container}" || true
    rm -rf "${home_dir}/mytool"
    log_success "mytool uninstalled from '${container}'."
}
```

Argument routing, CLI validation, locking, and help integration work out of the box once the file is placed in `bin/tools/`.

---

## Security Notes

- **Secrets and Authentication Tokens**: Sensitive secrets (such as `.webui_secret_key` or API keys) should never be stored in the root git repository. Open WebUI creates and manages its authentication secret keys directly inside each container's home directory (`~/.local/containers/<name>/.openwebui/`).
- **Network Isolation**: By default, services listen on `0.0.0.0` or `127.0.0.1` as configured in `localai.conf`. If deploying on untrusted or shared local networks, ensure firewalls are configured or set host bindings to `127.0.0.1`.
- **Locking & Concurrency**: Directory-based atomic locks prevent simultaneous overlapping install/update tasks across the same container instance.

---

## License

Copyright (c) 2026, wamuufan.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
