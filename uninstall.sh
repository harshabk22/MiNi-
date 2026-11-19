#!/bin/zsh
# Removes what install.sh created. Asks before deleting your personal data or the AI model.
ROOT="$(cd "$(dirname "$0")" && pwd)"
ask() { read "reply?$1 [y/N] "; [[ "$reply" == [yY]* ]]; }

pkill -f "Mini Flow.app/Contents/MacOS/MiniFlow" 2>/dev/null
rm -rf "$ROOT/assistant/.venv" "$ROOT/miniflow/.build" "$ROOT/miniflow/Mini Flow.app"
echo "Removed the Python environment and the built app."

if ask "Remove the 'mini' command from ~/.zshrc?"; then
  sed -i '' "/# Mini local assistant/d; \|alias mini=\"$ROOT/bin/mini\"|d" "$HOME/.zshrc" && echo "Removed."
fi
if ask "Delete the AI model from Ollama (~1.6 GB)?"; then
  ollama rm minicpm minicpm-think hf.co/openbmb/MiniCPM5-2B-GGUF:Q4_K_M 2>/dev/null; echo "Removed."
fi
if ask "Delete Mini's speech model for /talk (~143 MB)?"; then
  rm -rf "$HOME/Library/Caches/moonshine_voice"; echo "Removed."
fi
if ask "PERMANENTLY delete your personal data (memories, chats, logs, Mini Flow vocabulary)?"; then
  rm -rf "$ROOT/assistant/data" "$HOME/Library/Application Support/MiniFlow" "$HOME/Library/Logs/MiniFlow"
  defaults delete local.miniflow.dictation 2>/dev/null
  echo "Deleted."
fi
echo "Done. Ollama itself and macOS permissions were left as they are (remove 'Mini Flow' in Privacy & Security if you like)."
