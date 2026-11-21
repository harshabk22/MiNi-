# Mini Dictate — dictation anywhere

Hold **Fn**, speak, release → the text is pasted where your cursor is. Native macOS menu-bar app (Swift), using
Apple's on-device speech recognition and Apple Intelligence model — nothing to download.

**Requires** macOS 26+, Apple Silicon, Xcode Command Line Tools.

## Build & run
```bash
./build.sh                    # builds "Mini Dictate.app" + test tools into .build/
open "Mini Dictate.app"
```
`install.sh` copies the app to `~/Applications` so Spotlight can find it. When you develop, run the copy in this folder.

First launch: allow **Microphone**, **Accessibility** and **Input Monitoring** for “Mini Dictate”.
The app restarts by itself once they're granted, then registers itself to open at login. You can turn that off in the menu.
Recommended: System Settings → Keyboard → “Press 🌐 key to” → **Do Nothing**.

macOS links permissions to the app's signature. An ad-hoc signed rebuild counts as a new app, so the permissions reset.
Run `scripts/create-signing-cert.sh` once to avoid that.

## Use
| Do | Result |
|---|---|
| Hold Fn, speak, release | Push-to-talk |
| Tap Fn ×3 | Hands-free; tap Fn to stop (auto-stops after 1 minute) |
| Esc while listening | Cancel |
| Say "new line", "new paragraph", "bullet" | Exact layout |
| Menu → Names & words… | Teach it names it mishears |

## Source
| Path | What |
|---|---|
| `Sources/DictateCore/Recognizer.swift` | Microphone → Apple SpeechAnalyzer (live, on-device) |
| `Sources/DictateCore/NameFixer.swift` | Fixes misheard names that sound like ones in your list |
| `Sources/DictateCore/Formatter.swift` | Rules: fillers, spoken commands, self-corrections, lists, tone per app |
| `Sources/DictateCore/AIFormatter.swift` | Apple on-device AI pass + faithfulness check (never drops/invents words) |
| `Sources/DictateCore/FocusProbe.swift` · `Paster.swift` | Where the cursor is · paste with clipboard restore |
| `Sources/DictateCore/Vocabulary.swift` | Your names list + names from Mini's memory |
| `Sources/MiniDictate/` | The app: Fn key watcher, pop-up, hands-free mode, menu |
| `Sources/dictatetest`, `Sources/dictatecli` | Tests · transcribe a recording from the command line |
| `scripts/create-signing-cert.sh` | Optional: keeps permissions across rebuilds |

## Test
```bash
.build/dictatetest                       # rules, names, safety check (instant)
.build/dictatetest --audio --live --ai   # + speech model, live streaming path, Apple AI
.build/dictatetest --eval --audio --ai   # quality score on eval/*.tsv (add --verbose to see each miss)
.build/dictatetest --eval --ai --eval-dir ~/MiniDictateClips   # score your own recordings: clip.wav + clip.txt
```
Results so far are in [`eval/BASELINE.md`](eval/BASELINE.md).

**Measure accuracy on your own voice**
```bash
defaults write local.mini.dictate saveClips -bool true      # keep your next dictations (this Mac only, max 50)
# …dictate normally for a day, then for each clip in ~/Library/Application Support/MiniDictate/clips:
#    copy <clip>.heard.txt to <clip>.txt and fix it to what you actually said
.build/dictatetest --eval --eval-dir ~/Library/Application\ Support/MiniDictate/clips                    # current engine
.build/dictatetest --eval --eval-dir ~/Library/Application\ Support/MiniDictate/clips --engine dictation # Apple Dictation's engine
defaults write local.mini.dictate engine dictation          # switch the app if that one wins (delete the key to switch back)
```
