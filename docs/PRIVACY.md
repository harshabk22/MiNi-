# Privacy & safety

## What stays on your Mac
- Your conversations, dictation, memories, chat sessions, command log and Mini Dictate vocabulary.
  Mini: `assistant/data/` · Mini Dictate: `~/Library/Application Support/MiniDictate`, log in `~/Library/Logs/MiniDictate`.
- All AI runs locally: MiniCPM5-2B in Ollama, Apple's on-device speech and language models, Moonshine for `/talk`.

## What uses the internet
- One-time downloads during install / first use (Ollama, the model, Python packages, the /talk speech model).
- `web_search` and `read_webpage`: your search query goes to the search engine, and pages you read see a normal visit
  (your IP address). Use a VPN if you want to hide that.
- Commands you approve that download or install (curl, git pull, brew/pip/npm install).

## What Mini can never do (macOS sandbox, enforced by the kernel)
- Permanently delete, move or rename your files (deletes go to the Trash via a separate, approved tool).
- Write outside Desktop, Documents, Downloads (and its own workspace).
- Use admin rights, change system settings, kill other apps, control other apps, upload data (git push, ssh, curl -d).
- Read private folders: .ssh, Keychains, browser data, Mail, Messages, shell history.

## Mini Dictate
- Listens only while you hold Fn or after you triple-tap it (red indicator), and stops after 1 minute at most.
- Never pastes into password fields. Restores your clipboard after pasting.
- Its diagnostics log records permission status, counts and timings — never your words or typed keys.

## Delete everything
`./uninstall.sh` (asks before deleting personal data), or delete the folders listed above.
