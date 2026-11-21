# How Mini works

## Mini (assistant/mini.py)

```
you ──► prompt (persona + tools + core memories, cached) ──► MiniCPM5-2B in Ollama (16k context, ~2.3 GB RAM)
                     ▲                                              │
                     │                tool call (native XML format) ▼
                     └──── harness checks & tool results ◄── tools run in Python / macOS sandbox
```

**Harness** — the code around the 2B model makes it reliable:
- *Finish gate*: if the model says "done" after a failed action, it is sent back to correct itself.
- *Rescue*: a command written as text instead of a tool call is run the normal way (still needs your OK).
- *Repetition breaker*, *specific failure feedback*, *auto web search when unsure*, *step limit with a final answer*.
- *Prompt cache*: the start of the prompt never changes, so follow-ups re-read only the new message (~0.2 s).

**Tools**: system_info, web_search (multi-engine, parallel page reads, BM25-ranked passages, ~400 tokens),
read_webpage, find_files, read_file (text, PDF, Word), write_file / edit_file (diff + backup), move_file,
move_to_trash, open_file, clipboard, run_command, remember.

**Permissions** — four layers: block list → your approval (y / yes) → macOS sandbox (kernel-enforced: no deletes,
writes only in Desktop/Documents/Downloads, no network except approved downloads, no secrets) → audit log.

**Memory**: SQLite FTS5 (`data/memory.db`). Newest facts load once per session; related ones attach to the message.
Names are saved by code; junk and web-sourced "facts" are rejected.

**Voice** (`/talk`): Moonshine v2 Small Streaming (speech→text, built-in voice detection) → model → macOS `say`,
sentence by sentence. Press Enter to interrupt.

## Mini Dictate (dictate/)

```
Fn (hardware HID watcher) ─► mic ─► Apple SpeechAnalyzer (on-device, + your names as hints)
   ─► NameFixer (sounds-alike names from your list) ─► Rules (fillers, commands, corrections, lists)
   ─► Apple on-device AI when the text needs it (run-ons, lists, corrections, spoken numbers; few-shot prompt + your names)
   ─► Faithfulness check (keeps ≥85% of words in order, adds ≤15%; numbers as digits, applied self-corrections and
      one-for-one grammar fixes allowed; numbers, names and negations must never change; nothing invented)
   ─► paste at the cursor (⌘V, clipboard restored) — never into password fields
```
- Hold Fn = push-to-talk; tap Fn ×3 = hands-free (tap Fn to stop, 60 s limit).
- Menu-bar only (`LSUIElement`). Opens at login via `SMAppService`. Opening it again while it runs shows a "running" note.
- Pastes wherever the cursor is, except password fields and clearly non-text spots; "Pasted · Copy" fallback.
- macOS's automatic Escape on 🌐 is ignored; Fn + another key stays a normal shortcut.
- The microphone opens the moment Fn goes down and its audio is kept while the speech model loads, so the first words
  aren't lost; a tap or Fn + another key throws that audio away. Each press is its own session, so a quick release
  can't leave the microphone running.
- Paste waits until the target app is in front, reads the text box back (where the app allows it) to confirm
  "Pasted", restores your clipboard after 1.5 s only if you haven't copied something new, and says so when
  Accessibility is off instead of failing silently.
- Speech uses live partials for the preview and full-accuracy finals (no `fastResults`); segments are joined with a space.
- Speed: ~0.1–0.4 s speech→text; rules < 1 ms; AI pass ~0.7–1.5 s when used.
- Quality is measured with `dictatetest --eval` (see `dictate/eval/BASELINE.md`).
