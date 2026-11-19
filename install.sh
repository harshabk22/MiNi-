#!/bin/zsh
# Mini + Mini Flow — one-command setup for Apple Silicon Macs.
#   ./install.sh            set up everything (asks before installing anything system-wide)
#   ./install.sh --yes      same, without the questions
# Everything runs on your Mac. Models are downloaded once from Hugging Face / Apple / Moonshine and then work offline.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
MODEL="hf.co/openbmb/MiniCPM5-2B-GGUF:Q4_K_M"          # ~1.6 GB, Apache-2.0
YES=0; [[ "$1" == "--yes" ]] && YES=1

step() { print -P "\n%F{cyan}==>%f %B$1%b"; }
ok()   { print -P "    %F{green}✓%f $1"; }
warn() { print -P "    %F{yellow}!%f $1"; }
ask()  { [[ $YES == 1 ]] && return 0; read "reply?    $1 [y/N] "; [[ "$reply" == [yY]* ]]; }

step "Checking this Mac"
[[ "$(uname -m)" == "arm64" ]] || { warn "Mini needs an Apple Silicon Mac (M1 or newer)."; exit 1; }
MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
RAM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
ok "Apple Silicon · macOS $(sw_vers -productVersion) · ${RAM_GB} GB RAM"
(( RAM_GB < 8 )) && warn "Less than 8 GB RAM: Mini will be slow."

# ---------------------------------------------------------------- tools
step "Developer tools"
if ! xcode-select -p >/dev/null 2>&1; then
  warn "Apple's Command Line Tools are needed (for git/Swift). Opening Apple's installer…"
  xcode-select --install || true
  warn "Run ./install.sh again when that finishes."; exit 1
fi
ok "Command Line Tools"

if ! command -v uv >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1 && ask "Install 'uv' (fast Python installer) with Homebrew?"; then
    brew install uv
  elif ask "Install 'uv' with its official installer (astral.sh)?"; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
  else
    warn "uv is required to set up Mini's Python environment. Install it from https://docs.astral.sh/uv/ and re-run."; exit 1
  fi
fi
ok "uv $(uv --version | cut -d' ' -f2)"

if ! command -v ollama >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1 && ask "Install Ollama (runs the local AI model) with Homebrew?"; then
    brew install ollama
  else
    warn "Please install Ollama from https://ollama.com/download, then run ./install.sh again."; exit 1
  fi
fi
ok "Ollama $(ollama --version 2>/dev/null | awk '{print $NF}')"

# ---------------------------------------------------------------- the model (auto-download)
step "Local AI model (MiniCPM5-2B, ~1.6 GB, downloads once)"
if ! curl -s -o /dev/null http://127.0.0.1:11434/api/tags; then
  OLLAMA_FLASH_ATTENTION=1 OLLAMA_KV_CACHE_TYPE=q8_0 nohup ollama serve >/dev/null 2>&1 &!
  for i in {1..30}; do curl -s -o /dev/null http://127.0.0.1:11434/api/tags && break; sleep 0.5; done
fi
ollama pull "$MODEL"
ollama create minicpm -f "$ROOT/assistant/models/minicpm.Modelfile" >/dev/null
ollama create minicpm-think -f "$ROOT/assistant/models/minicpm-think.Modelfile" >/dev/null
ok "Model ready (also available in Ollama as 'minicpm' and 'minicpm-think')"

# ---------------------------------------------------------------- Mini (Python assistant)
step "Mini assistant (Python environment)"
cd "$ROOT/assistant"
[[ -d .venv ]] || uv venv -q --python 3.12 .venv
uv pip install -q --python .venv/bin/python -r requirements.txt
mkdir -p data
ok "Installed into assistant/.venv (your data goes to assistant/data/)"
.venv/bin/python -W ignore tests/test_mini.py >/dev/null 2>&1 && ok "Self-test passed" || warn "Self-test had failures — run: assistant/.venv/bin/python assistant/tests/test_mini.py"
chmod +x "$ROOT/bin/mini"

# ---------------------------------------------------------------- Mini Flow (dictation app)
step "Mini Flow (hold Fn to dictate anywhere)"
if (( MACOS_MAJOR < 26 )); then
  warn "Mini Flow needs macOS 26 or newer (it uses Apple's on-device speech models). Skipped."
else
  cd "$ROOT/miniflow"
  ./build.sh
  defaults write local.miniflow.dictation miniDataPath "$ROOT/assistant/data"   # lets Mini Flow learn names from Mini
  ok "Built 'Mini Flow.app' (no download: Apple's speech + AI models are part of macOS)"
fi

# ---------------------------------------------------------------- `mini` command
step "Terminal command"
LINE="alias mini=\"$ROOT/bin/mini\""
if grep -qF "$LINE" "$HOME/.zshrc" 2>/dev/null; then
  ok "'mini' command already set up"
elif ask "Add a 'mini' command to your terminal (~/.zshrc)?"; then
  print "\n# Mini local assistant\n$LINE" >> "$HOME/.zshrc"
  ok "Added — open a new Terminal window and type: mini"
else
  warn "Skipped. Start Mini with: $ROOT/bin/mini"
fi

step "Done"
print "    • Chat:      open a new Terminal and type  mini   (type / for commands)"
(( MACOS_MAJOR >= 26 )) && print "    • Dictation: open \"$ROOT/miniflow/Mini Flow.app\" — hold Fn to talk, tap Fn ×3 for hands-free"
print "    • First /talk in Mini downloads its speech model (~143 MB) automatically."
print "    • Docs:      README.md · docs/ARCHITECTURE.md · docs/PRIVACY.md"
