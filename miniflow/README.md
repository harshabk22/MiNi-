# Mini Flow — dictation anywhere

Hold **Fn**, speak, release → the text is pasted where your cursor is. Native macOS menu-bar app (Swift), using
Apple's on-device speech recognition and Apple Intelligence model — nothing to download.

**Requires** macOS 26+, Apple Silicon, Xcode Command Line Tools.

## Build & run
```bash
./build.sh                    # builds "Mini Flow.app" + test tools into .build/
open "Mini Flow.app"
```
First launch: allow **Microphone**, **Accessibility** and **Input Monitoring** for “Mini Flow”.
Recommended: System Settings → Keyboard → “Press 🌐 key to” → **Do Nothing**.

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
| `Sources/FlowCore/Recognizer.swift` | Microphone → Apple SpeechAnalyzer (live, on-device) |
| `Sources/FlowCore/NameFixer.swift` | Fixes misheard names that sound like ones in your list |
| `Sources/FlowCore/Formatter.swift` | Rules: fillers, spoken commands, self-corrections, lists, tone per app |
| `Sources/FlowCore/AIFormatter.swift` | Apple on-device AI pass + faithfulness check (never drops/invents words) |
| `Sources/FlowCore/FocusProbe.swift` · `Paster.swift` | Where the cursor is · paste with clipboard restore |
| `Sources/FlowCore/Vocabulary.swift` | Your names list + names from Mini's memory |
| `Sources/MiniFlow/` | The app: Fn key watcher, pop-up, hands-free mode, menu |
| `Sources/flowtest`, `Sources/flowcli` | Tests · transcribe a recording from the command line |
| `scripts/create-signing-cert.sh` | Optional: keeps permissions across rebuilds |

## Test
```bash
.build/flowtest                       # rules, names, safety check (instant)
.build/flowtest --audio --live --ai   # + speech model, live streaming path, Apple AI
```
