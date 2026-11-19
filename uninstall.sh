#!/bin/zsh
# Removes what install.sh created. Asks before deleting your personal data or the AI model.
ROOT="$(cd "$(dirname "$0")" && pwd)"
ask() { read "reply?$1 [y/N] "; [[ "$reply" == [yY]* ]]; }

pkill -f "Mini Dictate.app/Contents/MacOS/MiniDictate" 2>/dev/null
pkill -f "Mini Flow.app/Contents/MacOS/MiniFlow" 2>/dev/null   # old name
rm -rf "$ROOT/assistant/.venv" "$ROOT/dictate/.build" "$ROOT/dictate/Mini Dictate.app" "$ROOT/miniflow" "$HOME/Applications/Mini Dictate.app"
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
if ask "PERMANENTLY delete your personal data (memories, chats, logs, Mini Dictate vocabulary)?"; then
  rm -rf "$ROOT/assistant/data" "$HOME/Library/Application Support/MiniDictate" "$HOME/Library/Logs/MiniDictate" \
         "$HOME/Library/Application Support/MiniFlow" "$HOME/Library/Logs/MiniFlow"   # old names
  defaults delete local.mini.dictate 2>/dev/null; defaults delete local.miniflow.dictation 2>/dev/null
  echo "Deleted."
fi
echo "Done. Ollama itself and macOS permissions were left as they are (remove 'Mini Dictate' from Privacy & Security and Login Items if you like)."
