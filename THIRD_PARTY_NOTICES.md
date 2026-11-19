# Third-party notices

This repository contains only original source code, released under the [MIT License](LICENSE).
**No third-party code, models or data are bundled here.** `install.sh` downloads them onto your Mac,
and each one keeps its own license.

## AI models (downloaded at install or first use)
| Component | License | Source |
|---|---|---|
| MiniCPM5-2B (GGUF, Q4_K_M) | Apache-2.0 | https://huggingface.co/openbmb/MiniCPM5-2B-GGUF |
| Moonshine English Small Streaming (`/talk`) | MIT | https://github.com/moonshine-ai/moonshine |

Mini Flow uses Apple's on-device Speech and Foundation Models frameworks that are built into macOS.
They are covered by Apple's macOS license, and nothing is downloaded or redistributed.

## Software installed by `install.sh`
| Component | License |
|---|---|
| [Ollama](https://ollama.com) | MIT |
| [uv](https://docs.astral.sh/uv/) | MIT or Apache-2.0 |

## Python packages (`assistant/requirements.txt` and their dependencies)
| Package | License |
|---|---|
| httpx, httpcore, pypdf, prompt_toolkit, lxml, click, idna, dateparser, python-dateutil | BSD-3-Clause |
| jusText | BSD-2-Clause |
| ddgs, moonshine-voice, anyio, h11, primp, platformdirs, filelock, urllib3, sounddevice, pytz, tzlocal, wcwidth, charset-normalizer | MIT |
| cffi | MIT-0 |
| trafilatura, courlan, htmldate, requests, tzdata, google-crc32c | Apache-2.0 |
| certifi | MPL-2.0 |
| tqdm | MPL-2.0 and MIT |
| numpy | BSD-3-Clause, with bundled 0BSD / MIT / Zlib parts |
| regex | Apache-2.0 and CNRI-Python |
| typing_extensions | PSF-2.0 |

None of these packages are GPL or AGPL. MPL-2.0 applies file by file and only matters if you change those packages' own files,
which this project doesn't. This list was checked on 2026-11-19. Newer package versions may differ.

## Trademarks
Apple, macOS, Apple Intelligence and Apple Silicon are trademarks of Apple Inc. MiniCPM, Ollama, Moonshine,
DuckDuckGo, Bing, Yahoo and Google are the names or marks of their respective owners. This project is not affiliated with,
endorsed by or sponsored by any of them, and it uses these names only to describe what it works with.
