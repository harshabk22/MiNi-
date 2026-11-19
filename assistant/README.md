# Mini — the assistant

A local AI assistant for the Terminal, built on **MiniCPM5-2B** running in [Ollama](https://ollama.com).

## Run
```bash
../bin/mini            # or just `mini` if you let install.sh add the command
```
Type `/` for the command menu.

## Files
| Path | What |
|---|---|
| `mini.py` | The whole assistant: chat loop, tools, memory, sandbox, voice mode |
| `models/minicpm.Modelfile` | Ollama settings for normal chat (persona, sampling, context) |
| `models/minicpm-think.Modelfile` | Same model with step-by-step "thinking" turned on |
| `requirements.txt` | Python packages (installed into `.venv` by `install.sh`) |
| `tests/test_mini.py` | Offline self-tests (no model or internet needed) |
| `data/` | **Your** memories, chats and logs — created at runtime, ignored by git |

## Commands
| Command | Does |
|---|---|
| `/talk` | Voice conversation (speak, Mini answers out loud) |
| `/think [on\|off]` | Deeper reasoning for math, logic, tricky code |
| `/context` | How full the model's working memory is |
| `/memories` · `/remember <fact>` · `/forget <n>` | Long-term memory |
| `/sessions` · `/resume [n]` | Saved chats |
| `/clear` · `/delete [all]` | Start fresh / delete conversation (and optionally everything) |
| `/backups` · `/permissions` · `/help` · `/exit` | |

## Test
```bash
.venv/bin/python tests/test_mini.py
```
