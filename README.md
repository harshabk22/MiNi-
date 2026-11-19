# Mini

**A private AI assistant and a voice-dictation app for Apple Silicon Macs — everything runs on your Mac.**

No cloud AI, no account, no usage limits. Built to run comfortably on an 8 GB MacBook.

| | What it does | Powered by |
|---|---|---|
| 🧠 **Mini** | Terminal assistant: answers questions, searches the web, reads files and PDFs, does small tasks on your Mac (with your approval), remembers you, and talks out loud. | MiniCPM5-2B via [Ollama](https://ollama.com) — ~1.6 GB, downloaded automatically |
| 🎙️ **Mini Dictate** | Hold **Fn** anywhere, speak, release — clean, formatted text is pasted where your cursor is (WhatsApp, Mail, browser, editors). | Apple's on-device speech + Apple Intelligence — built into macOS, nothing to download |

---

## Contents
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Using Mini](#using-mini)
- [Using Mini Dictate](#using-mini-dictate)
- [Project structure](#project-structure)
- [Development](#development)
- [Troubleshooting](#troubleshooting)
- [Privacy & safety](#privacy--safety)
- [Limits](#limits)
- [Uninstall](#uninstall)
- [Credits](#credits)
- [License](#license)
- [Legal](#legal)

## Requirements
- Mac with **Apple Silicon** (M1 or newer), **8 GB RAM** or more
- **macOS 26+** for Mini Dictate (Mini also runs on older macOS)
- Internet once, for installation and the model download (~1.6 GB)

## Quick start
```bash
git clone https://github.com/harshabk22/MiNi-.git Mini
cd Mini
./install.sh
```
The installer:
1. checks your Mac (chip, macOS, RAM)
2. installs what's missing — **asking first** — Apple Command Line Tools, [`uv`](https://docs.astral.sh/uv/), Ollama
3. **downloads the AI model automatically** and prepares it
4. sets up Mini's Python environment and runs its self-tests
5. builds Mini Dictate, puts it in `~/Applications` and starts it
6. offers to add a `mini` command to your Terminal

## Using Mini
Open a new Terminal window and type **`mini`**. Type **`/`** to see every command.

```
you › how much RAM is left?
you › find my resume pdf and summarize it
you › create a folder called notes on my Desktop
you › what's new in Python 3.15?
```

| Command | What it does |
|---|---|
| `/talk` | Voice conversation — speak, Mini answers out loud |
| `/think` | Deeper step-by-step reasoning |
| `/memories`, `/remember`, `/forget` | What Mini remembers about you |
| `/sessions`, `/resume` | Continue an earlier chat (or start with `mini --resume`) |
| `/context` | How full the model's working memory is |
| `/delete`, `/delete all` | Delete the conversation / everything (asks first) |
| `/permissions` | What Mini is and isn't allowed to do |

Every action on your Mac needs your approval: **`y`** for read-only, **`yes`** for changes.

## Using Mini Dictate
The installer starts it, and a 🎙 appears in the menu bar.

**First start: permissions.** macOS asks for each one; only you can allow them.
| Permission | Why |
|---|---|
| Microphone | Hear you while you hold Fn |
| Input Monitoring | Notice the Fn key |
| Accessibility | Paste at your cursor and skip password fields |
| Documents folder (sometimes) | Read names from Mini's memory, to spell them right |

Mini Dictate opens the right Settings page and restarts by itself once you've switched it on.

**Starting and stopping**
| Situation | What to do |
|---|---|
| After a restart or log-in | Nothing. It starts automatically (menu → **Open at login** turns this off). |
| You quit it | Spotlight (**⌘ Space**) → type **Mini Dictate** → Enter. Or Finder → your home folder → Applications. |
| Not sure if it's running | Open it again as above; it shows "Mini Dictate is running". |
| Mini (the assistant) | No background app. Open Terminal and type **`mini`**; it starts Ollama if needed. |

| Do | Result |
|---|---|
| **Hold Fn**, speak, release | Text is pasted at your cursor |
| **Tap Fn three times** | Hands-free mode — tap Fn once to stop (stops by itself after 1 minute) |
| **Esc** while listening | Cancel |
| Say "new line", "new paragraph", "bullet" | Exact layout |
| Speak a list ("first… second…") | Numbered or bulleted list |
| "at 10, no actually 11" | Keeps only "11" |

Names it gets wrong → menu → **Names & words…**

## Project structure
```
Mini/
├── README.md                      ← you are here
├── LICENSE                        MIT
├── THIRD_PARTY_NOTICES.md         licenses of everything install.sh downloads
├── install.sh                     one-command setup (downloads the model)
├── uninstall.sh                   removal (asks before deleting data or the model)
├── bin/
│   └── mini                       launcher: starts Ollama if needed, then Mini
├── assistant/                     🧠 Mini — Python
│   ├── README.md
│   ├── mini.py                    chat loop, tools, memory, sandbox, voice
│   ├── models/                    Ollama model settings (persona, sampling)
│   ├── tests/test_mini.py         offline self-tests
│   ├── requirements.txt
│   └── data/                      your memories & chats (created at runtime, git-ignored)
├── dictate/                       🎙️ Mini Dictate — Swift, native macOS app
│   ├── README.md
│   ├── Sources/
│   │   ├── DictateCore/           speech, formatting, names, AI + safety check, paste
│   │   ├── MiniDictate/           menu-bar app: Fn key, pop-up, hands-free, open at login
│   │   ├── dictatetest/           tests
│   │   └── dictatecli/            transcribe a recording from the command line
│   ├── Resources/                 Info.plist, entitlements
│   ├── build.sh                   builds "Mini Dictate.app"
│   └── scripts/create-signing-cert.sh   optional: keep permissions across rebuilds
└── docs/
    ├── ARCHITECTURE.md            how it works
    └── PRIVACY.md                 what stays local, what uses the internet
```

## Development
```bash
# Mini — run tests (offline, ~2 s)
assistant/.venv/bin/python assistant/tests/test_mini.py

# Mini Dictate — build and test
cd dictate && ./build.sh
.build/dictatetest --audio --live --ai
```
More detail in [`assistant/README.md`](assistant/README.md), [`dictate/README.md`](dictate/README.md) and
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Troubleshooting
| Problem | Fix |
|---|---|
| `mini` command not found | Open a **new** Terminal window, or run `source ~/.zshrc` |
| "Ollama isn't running" | `bin/mini` starts it automatically; or run `ollama serve` |
| Fn does nothing | Allow **Input Monitoring** and **Accessibility** for "Mini Dictate" (menu → Permissions…) |
| 🎙 icon not in the menu bar | It may be hidden behind the notch. Quit other menu-bar apps, or open Mini Dictate again from Spotlight to check it's running |
| Doesn't start after restart | Menu → tick **Open at login**, or System Settings → General → Login Items → add Mini Dictate |
| "Mini Flow" still installed (old name) | Quit it, then remove it from Login Items and Privacy & Security. Re-run `./install.sh` |
| A macOS pop-up (emoji / dictation) appears with Fn | System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing** |
| Permissions lost after rebuilding Mini Dictate | Run `dictate/scripts/create-signing-cert.sh` once, then rebuild |
| Text not pasted in some app | Click **Copy** on the pop-up, or menu → Recent |

## Privacy & safety
- **Local AI only** — conversations, dictation and memories never leave your Mac. Internet is used only for web search,
  reading pages, and the one-time downloads.
- **Kernel-enforced limits** — Mini can't permanently delete, move or rename files, write outside
  Desktop/Documents/Downloads, use admin rights, change system settings, upload data, or read private folders
  (`.ssh`, Keychains, browser data). Deletes go to the Trash.
- **Mini Dictate** listens only while you hold Fn (or after a triple-tap, max 1 minute) and never pastes into password fields.

Full details: [`docs/PRIVACY.md`](docs/PRIVACY.md)

## Limits
- **Mini is a small (2B) model.** It can be wrong — check facts, math and code before relying on them.
- **Not for** medical, legal or financial decisions, or anything where a mistake is costly.
- **Mac only.** Apple Silicon required; no Windows, Linux or Intel Macs.
- **Mini Dictate needs macOS 26+.** Its AI cleanup step uses Apple Intelligence; with it off, only the rule-based cleanup runs.
- **Approve carefully.** Mini asks before every action — read what it will run before typing `y` / `yes`.

## Uninstall
```bash
./uninstall.sh
```
Removes the environment and app; asks before deleting the AI model or your personal data.

## Credits
[MiniCPM5-2B](https://huggingface.co/openbmb/MiniCPM5-2B) (Apache-2.0, OpenBMB) ·
[Ollama](https://ollama.com) (MIT) · [Moonshine Voice](https://github.com/moonshine-ai/moonshine) (MIT) ·
httpx · ddgs · trafilatura · pypdf · prompt_toolkit · Apple Speech & Foundation Models (macOS).

## License
[MIT](LICENSE): you are free to use, change and share this code, as long as you keep the copyright notice. It comes with no warranty.
No models or third-party code are stored in this repo. They are downloaded during install and keep their own licenses,
all of them permissive (MiniCPM5-2B is Apache-2.0). See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## Legal
- **Your responsibility.** You decide what Mini runs and what you dictate. Use it in line with the law and with other people's rights.
- **Web search** uses the `ddgs` library, which reads public search-engine results without an API key. Some search
  engines' terms don't allow automated access. Keep it to light personal use; for anything heavier, use an official search API.
- **Recording.** Mini Dictate and `/talk` listen only while you activate them and keep no audio. Some places have
  laws about recording other people. Don't use these features to capture other people's conversations without their consent.
- **Not affiliated** with Apple, OpenBMB, Ollama, Moonshine AI or any search engine. Their names are their trademarks
  and are used here only to say what this project works with.
