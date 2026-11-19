"""Mini: a local assistant on MiniCPM5-2B (Ollama) with tools, memory and thinking mode.

Tools (in the model's native XML format):
  system_info   - RAM, disk, CPU, battery, top apps (read-only, no approval)
  web_search    - search, read the top pages in parallel, keep only the best-ranked passages (BM25)
  read_webpage  - the most relevant passages of one page
  run_command   - zsh command in a macOS sandbox, after your approval (see /permissions)
  remember      - save a fact about you or your work to long-term memory

Chat commands:  /think  /memories  /remember <fact>  /forget <n>  /clear  /delete [all]  /permissions  /help  /exit
Run:  bin/mini   (see README.md — install.sh sets everything up)
"""

import datetime
import ipaddress
import json
import re
import socket
import sqlite3
import subprocess
import sys
import warnings
from pathlib import Path
from urllib.parse import urlparse

warnings.filterwarnings("ignore")
import httpx  # noqa: E402

HERE = Path(__file__).resolve().parent
DATA = HERE / "data"                    # your memories, sessions, logs (never shared)
DATA.mkdir(exist_ok=True)
DB = DATA / "memory.db"
OLLAMA = "http://127.0.0.1:11434/api/generate"
MODEL = "hf.co/openbmb/MiniCPM5-2B-GGUF:Q4_K_M"
MAX_TOOL_STEPS = 6
# Context: 16k tokens = 2.3 GB RAM (measured). 32k = 3.3 GB and reading it takes ~90 s on an M3, so 16k is the
# sweet spot. Budget: ~1.5k system+tools, ~9k history, the rest for the reply.
NUM_CTX = 16384
HISTORY_CHARS = 32_000          # ~9k tokens (≈3.5 chars per token)
TOOL_KEEP_CHARS = 800           # tool outputs are shortened to this after they've been used
KEEP_ALIVE = "10m"              # keep the model (and its cache) loaded between messages, then free the RAM
DIM, BOLD, YEL, RESET = "\033[2m", "\033[1m", "\033[33m", "\033[0m"

PERSONA = """You are Mini, a sharp, friendly AI assistant running locally on this Mac.
Identity: YOU are Mini. The person typing to you is the USER, a human, not Mini. When the user says "I", "me" or "my",
they mean themselves. If they ask "who am I?", answer with what you know about THEM from memory or this conversation
(for example their name). If you know nothing about them yet, say so and ask their name.
- Match your length to the message: a greeting or short message gets a short, natural reply (one or two sentences).
  Greet the user by THEIR name if you know it, e.g. "Hi {name}! How can I help?" Never call the user Mini.
- If a message is very short, unclear, or looks like a typo (e.g. "hwy" = "hey"), assume the most common meaning
  or ask what they meant. Never invent obscure meanings, commands, or facts to fill the gap.
- Be direct: lead with the answer, then the key details. Use bullet points and short code blocks when they help.
- Be honest: if you are not sure, say so plainly. Never invent facts, numbers, links, or quotes.
- For code: give working, minimal code and explain only what is non-obvious.
- Ask one short clarifying question only when the request is truly ambiguous. If the user names a
  folder (Downloads, Desktop, Documents) use it; if they don't, default to ~/Desktop and say so.

How to use your tools (this Mac runs macOS on Apple Silicon with zsh; Linux-only commands like free, /proc,
apt, systemctl do NOT exist here):
- system_info: for RAM, memory, disk space, CPU, battery, uptime or which apps use the most memory. Always use this
  instead of run_command for those questions. It needs no approval.
- web_search: for current events, prices, versions, people, products, or any fact you are not sure about. It returns
  ranked evidence passages numbered [1], [2]... Answer FROM that evidence and cite like [1]. If a name is ambiguous,
  lead with the most prominent meaning that matches the evidence and mention others in one short line. Skip results
  that are about a different name. Use read_webpage only when you need more from one specific URL.
- Files (Desktop, Documents, Downloads): find_files when unsure of a name; read_file before changing a file;
  edit_file to change part of a file (old_text copied exactly from read_file); write_file for new files or full
  rewrites; open_file to show a file (e.g. an HTML page in the browser); move_file to move/rename; move_to_trash to
  delete (recoverable). Never use cat/echo/heredocs, mv or rm for these.
- run_command: other Mac tasks with simple commands: mkdir -p ~/Desktop/x, ls -la ~/Downloads, git status/pull/clone,
  curl -L -o ~/Downloads/f URL, brew/pip3/npm install, running a script. The user approves each action.
- clipboard: read (asks the user) or write ("copy this").
- Impossible (don't try): permanent deletion, sudo, system settings, killing apps, passwords, uploading data (git push,
  ssh, scp). Give the user the exact command to run themselves, with exact paths from this conversation.
- remember: when the user tells you a lasting fact about themselves, their projects, or their preferences.
- If you don't know something or a name is unfamiliar, use web_search instead of asking the user to clarify.
- Otherwise answer directly without tools."""
TOOLS = [
    {"type": "function", "function": {"name": "system_info", "description": "Get this Mac's RAM usage, disk space, CPU, battery, uptime and top memory-using apps. No approval needed.",
        "parameters": {"type": "object", "properties": {}, "required": []}}},
    {"type": "function", "function": {"name": "web_search", "description": "Search the web and read the top pages. Returns the most relevant passages with numbered sources.",
        "parameters": {"type": "object", "properties": {"query": {"type": "string", "description": "Search query"}}, "required": ["query"]}}},
    {"type": "function", "function": {"name": "read_webpage", "description": "Read the most relevant parts of one web page.",
        "parameters": {"type": "object", "properties": {"url": {"type": "string", "description": "Full http(s) URL"}}, "required": ["url"]}}},
    {"type": "function", "function": {"name": "run_command", "description": "Run a zsh command on the user's Mac (macOS), in their home folder. The user approves it first. Returns stdout/stderr.",
        "parameters": {"type": "object", "properties": {"command": {"type": "string", "description": "The shell command"}}, "required": ["command"]}}},
    {"type": "function", "function": {"name": "move_to_trash", "description": "Move a file or folder in Desktop, Documents or Downloads to the macOS Trash (recoverable). The user approves.",
        "parameters": {"type": "object", "properties": {"path": {"type": "string", "description": "Exact path, e.g. ~/Downloads/old.zip"}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "move_file", "description": "Move or rename a file/folder within Desktop, Documents, Downloads. Never overwrites. The user approves.",
        "parameters": {"type": "object", "properties": {"source": {"type": "string", "description": "Exact current path"}, "destination": {"type": "string", "description": "New path or an existing folder"}}, "required": ["source", "destination"]}}},
    {"type": "function", "function": {"name": "find_files", "description": "Find files/folders by (part of) name in Desktop, Documents, Downloads. Use before reading or editing if unsure of the exact path.",
        "parameters": {"type": "object", "properties": {"query": {"type": "string"}, "folder": {"type": "string", "description": "Optional folder to search in"}}, "required": ["query"]}}},
    {"type": "function", "function": {"name": "read_file", "description": "Read a text/code file, PDF or Word document, with line numbers.",
        "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "start_line": {"type": "integer", "description": "Optional, for long files"}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "write_file", "description": "Create a new file or replace a whole file (Desktop, Documents, Downloads). The user approves.",
        "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}, "required": ["path", "content"]}}},
    {"type": "function", "function": {"name": "edit_file", "description": "Change part of a file: replace old_text (copied exactly from read_file, without line numbers) with new_text. The user approves.",
        "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "old_text": {"type": "string"}, "new_text": {"type": "string"}}, "required": ["path", "old_text", "new_text"]}}},
    {"type": "function", "function": {"name": "open_file", "description": "Open a file or folder in its default app, e.g. an HTML page in the browser. The user approves.",
        "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "clipboard", "description": "Read or write the macOS clipboard.",
        "parameters": {"type": "object", "properties": {"action": {"type": "string", "enum": ["read", "write"]}, "text": {"type": "string", "description": "For write"}}, "required": ["action"]}}},
    {"type": "function", "function": {"name": "remember", "description": "Save a lasting fact about the user or their work to long-term memory.",
        "parameters": {"type": "object", "properties": {"fact": {"type": "string", "description": "One short fact"}}, "required": ["fact"]}}},
]

# Exactly the tool block from MiniCPM5's own chat template.
TOOL_BLOCK = ("# Tools\n\nYou are provided with function signatures within <tools></tools> XML tags:\n<tools>"
              + "".join("\n" + json.dumps(t, ensure_ascii=False) for t in TOOLS)
              + "\n</tools>\n\nTool usage guidelines:\n- You may call zero or more functions. If no function calls are needed, "
              "just answer normally and do not include any <function ... </function>.\n- When calling a function, return an XML "
              "object within <function ... </function> using:\n<function name=\"function-name\"><param name=\"param-name\">"
              "param-value</param></function>\n- param-value may be multi-line. If it contains <, & or newline characters, wrap "
              "it in a CDATA block: <param name=\"param-name\"><![CDATA[...multi-line value...]]></param>")

# ----------------------------------------------------------------------------- permissions
# Sandbox first: macOS itself enforces the hard limits, so the word filter only has to catch things that are
# never wanted. Nothing typed in the chat can loosen any of this; only editing this file can.
#  1. OS sandbox (kernel-enforced, can't be tricked):
#       - NO deleting, moving or renaming files anywhere outside Mini's own workspace
#       - writing/creating files ONLY in WRITE_FOLDERS (+ workspace and temp); everything else is read-only
#       - NO network, NO controlling other apps (Apple Events), NO killing/signalling other processes
#       - NO reading secret folders (.ssh, Keychains, browser data, Mail, Messages, shell history...)
#  2. BLOCKED list: refused before you are asked, with a clear reason (delete verbs, sudo, system settings...)
#  3. Approval: read-only commands need "y"; anything that can write needs "yes"
#  4. Audit log: every command, your decision and the result go to commands.log
H = str(Path.home())
WORKSPACE = DATA / "workspace"          # Mini's scratch folder: may also delete/rename here
WRITE_FOLDERS = [f"{H}/Desktop", f"{H}/Documents", f"{H}/Downloads"]   # create/write allowed, delete never
AUDIT_LOG = DATA / "commands.log"
TEMP_DIRS = ["/private/tmp", "/private/var/folders"]
SECRET_PATHS = [f"{H}/.ssh", f"{H}/.aws", f"{H}/.gnupg", f"{H}/.netrc", f"{H}/.config/gh", f"{H}/.docker",
                f"{H}/.kube", f"{H}/Library/Keychains", f"{H}/Library/Cookies", f"{H}/Library/Messages",
                f"{H}/Library/Mail", f"{H}/Library/Application Support/Google/Chrome",
                f"{H}/Library/Application Support/Firefox", f"{H}/Library/Safari", f"{H}/.zsh_history",
                f"{H}/.bash_history", f"{H}/.env"]

BLOCKED = {
    "deletes files permanently (use the move_to_trash tool instead)":
        [r"\brm\b", r"\brmdir\b", r"\bunlink\b", r"\bshred\b", r"\bsrm\b", r"\btrash\b", r"-delete\b",
         r"\bgit\s+clean\b", r"\bgit\s+rm\b", r"\bgit\s+branch\s+-D\b", r"\bfind\b.*-exec\s+rm"],
    "moves or renames files in the shell (use the move_file tool instead)": [r"\bmv\b", r"\bgit\s+mv\b"],
    "throws away git work": [r"\bgit\s+reset\s+--hard\b", r"\bgit\s+checkout\s+--\s", r"\bgit\s+restore\b",
                             r"\bgit\s+stash\s+(drop|clear)\b"],
    "needs admin rights": [r"\bsudo\b", r"(?<![\w-])su\b", r"\bdoas\b"],
    "changes system settings": [r"\bshutdown\b", r"\breboot\b", r"\bhalt\b", r"\blaunchctl\b", r"\bdefaults\s+(write|delete)\b",
                                r"\bcsrutil\b", r"\bnvram\b", r"\bdiskutil\s+(erase|partition|unmount|eject|apfs)", r"\bmkfs",
                                r"\bdd\b", r"\bpmset\s+(?!-g)", r"\bsystemsetup\b", r"\bnetworksetup\b", r"\bspctl\b",
                                r"\btccutil\b", r"\bkextload\b", r"\bcrontab\b", r"\bsoftwareupdate\b"],
    "stops other apps": [r"\bkill(all)?\b", r"\bpkill\b"],
    "touches passwords or keys": [r"\bsecurity\b", r"\bpasswd\b", r"\bssh-keygen\b", r"\bssh-add\b"],
    "uploads data or logs in to another computer": [
        r"\bgit\s+push\b", r"\bscp\b", r"\brsync\b", r"\bsftp\b", r"\bftp\b", r"\bnc\b", r"\bncat\b", r"\btelnet\b",
        r"(?<![\w./-])ssh\b", r"\b(curl|wget)\b.*(\s-d\b|--data|\s-F\b|--form|\s-T\b|--upload|--post|-X\s*(POST|PUT|PATCH|DELETE)|--method)"],
    "installs software globally with admin-style flags": [r"\bnpm\s+(i|install)\s+.*(-g|--global)\b", r"--break-system-packages"],
    "is a fork bomb": [r":\(\)\s*\{"],
}

# Allowed with "yes", each with its own sandbox: network on only for these commands, package folders writable only
# for installs. Everything else still runs with no network.
INSTALL_PATS = [r"\bbrew\s+(install|uninstall|remove|upgrade|reinstall|update|tap)\b", r"\bpip3?\s+(install|uninstall)\b",
                r"\bpython3?\s+-m\s+pip\s+(install|uninstall)\b", r"\bnpm\s+(i|install|uninstall|ci|update)\b",
                r"\buv\s+(pip\s+install|add|sync)\b", r"\bgem\s+install\b"]
_SEG = r"(?:^|[;&|(]\s*|&&\s*|\|\|\s*)\s*"
NETWORK_PATS = [_SEG + r"(curl|wget|ping|dig|nslookup|host|traceroute)\b", r"\bgit\s+(pull|fetch|clone)\b",
                r"\bollama\s+pull\b"]
PACKAGE_DIRS = ["/opt/homebrew", f"{H}/Library/Caches", f"{H}/Library/Logs/Homebrew", f"{H}/.npm", f"{H}/.cache",
                f"{H}/Library/Python", f"{H}/.local", f"{H}/.ollama", f"{H}/.cargo", f"{H}/go"]

# Read-only commands: these only need "y". Everything else that isn't blocked needs "yes".
READ_ONLY = {"ls", "pwd", "cat", "head", "tail", "wc", "df", "du", "ps", "uptime", "whoami", "date", "cal",
             "uname", "sw_vers", "which", "whereis", "type", "echo", "printf", "grep", "egrep", "rg", "find", "file",
             "stat", "tree", "sort", "uniq", "cut", "diff", "hostname", "id", "groups", "vm_stat", "sysctl",
             "memory_pressure", "top", "system_profiler", "ioreg", "ifconfig", "netstat", "lsof", "mdfind", "mdls",
             "pmset", "ollama", "brew", "git", "pip", "pip3", "npm", "node", "python3", "basename", "dirname",
             "realpath", "md5", "shasum", "column", "jq"}
READ_ONLY_SUBCMDS = {"git": {"status", "log", "diff", "show", "branch", "remote", "--version", "blame", "shortlog"},
                     "brew": {"list", "info", "search", "--version", "outdated", "config"},
                     "pip": {"list", "show", "--version"}, "pip3": {"list", "show", "--version"},
                     "npm": {"list", "ls", "--version", "-v"}, "node": {"--version", "-v"},
                     "python3": {"--version", "-V"}, "pmset": {"-g"}, "top": {"-l"},
                     "ollama": {"list", "ps", "show", "--version", "-v"}}


SAFE_HINTS = {
    "moves or renames files in the shell (use the move_file tool instead)":
        "To create a folder somewhere, make it directly there: mkdir -p ~/Downloads/NAME. To move or rename, call the "
        "move_file tool. To copy, use cp.",
    "deletes files permanently (use the move_to_trash tool instead)":
        "Call the move_to_trash tool with the exact path; it is recoverable from the Trash.",
    "uploads data or logs in to another computer": "Downloading is allowed (curl -L -o ~/Downloads/file URL).",
    "stops other apps": "To see what is running use ps -Ao pid,comm or system_info.",
}


INTERPRETERS = {"sh", "bash", "zsh", "python", "python3", "node", "perl", "ruby", "osascript", "php", "lua", "fish"}


def shell_skeleton(command: str) -> str:
    """The parts of a command the shell actually executes. File content written with a heredoc (cat > f << EOF ... EOF)
    and plain quoted text are removed, so words like "kill" or "<h1>" inside them aren't mistaken for commands.
    Code that is really executed (bash -c '...', python3 -c "...", python3 << EOF) is kept and checked."""
    text = command.replace("\\\n", " ")
    def heredoc(m):
        prog = Path(m.group(1)).name
        return m.group(0) if prog in INTERPRETERS else m.group(0)[: m.start(3) - m.start(0)] + "\n"
    text = re.sub(r"(?m)^\s*(\S+)[^\n]*?<<-?\s*['\"]?(\w+)['\"]?[^\n]*\n(.*?)^\s*\2\s*$", heredoc, text, flags=re.S)
    text = re.sub(r"(?<=\s-[ce])\s+(['\"])(.*?)\1", lambda m: " " + m.group(2), text, flags=re.S)   # keep -c/-e code
    return re.sub(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"", "''", text)


def check_command(command: str) -> tuple[str, str]:
    """Return ('blocked', reason) | ('read-only', '') | ('changes', '') | ('network', '') | ('install', '')."""
    flat = shell_skeleton(command)
    for reason, pats in BLOCKED.items():
        for pat in pats:
            if re.search(pat, flat):
                return "blocked", reason
    if any(re.search(p, flat) for p in INSTALL_PATS):
        return "install", ""
    if any(re.search(p, flat) for p in NETWORK_PATS):
        return "network", ""
    if re.search(r"(?<![0-9&])>(?!\s*/dev/null)|\btee\b|\bsed\s+-i|\$\(|`|\beval\b|\bxargs\b|\bsort\b.*\s-o\b|"
                 r"-fprint|-fls\b|-exec\b|-ok\b|\bgit\s+branch\s+\S*[^\s-]", flat):
        return "changes", ""
    for seg in re.split(r"\|\||&&|;|\|", flat):
        words = seg.split()
        if not words:
            continue
        prog, sub = words[0], (words[1] if len(words) > 1 else "")
        if prog not in READ_ONLY or (prog in READ_ONLY_SUBCMDS and sub not in READ_ONLY_SUBCMDS[prog]):
            return "changes", ""
    return "read-only", ""


def sandbox_profile(kind: str = "changes") -> str:
    """Kernel rules for one command. Network only for 'network'/'install'; package folders only for 'install'."""
    q = lambda p: '"' + p.replace("\\", "\\\\").replace('"', '\\"') + '"'
    sub = lambda paths: " ".join(f"(subpath {q(p)})" for p in paths)
    writable = [str(WORKSPACE)] + TEMP_DIRS + WRITE_FOLDERS + (PACKAGE_DIRS if kind == "install" else [])
    return ("(version 1)(allow default)"
            + ("" if kind in ("network", "install") else "(deny network*)")
            + "(deny appleevent-send)"
            "(deny signal)(allow signal (target self))"
            "(deny file-write*)"
            f'(allow file-write* {sub(writable)} (literal "/dev/null") (literal "/dev/tty") (subpath "/dev/fd"))'
            f"(deny file-write-unlink {sub(WRITE_FOLDERS)})"
            # git must create/rename/delete its own lock files inside .git (clone, pull, add, commit); your files stay
            # undeletable. Rule order matters: this later allow wins only for paths inside a .git folder.
            f'(allow file-write-unlink (regex #"^{re.escape(H)}/(Desktop|Documents|Downloads)/(.+/)?\\.git(/|$)"))'
            f"(deny file-read* {sub(SECRET_PATHS)})")


def _inside_write_folders(path: str) -> Path | None:
    """Resolve a path (following symlinks) and return it only if it is strictly inside Desktop/Documents/Downloads."""
    p = Path(path.strip().strip("'\"")).expanduser()
    if not p.is_absolute():
        p = Path.home() / p
    try:
        r = p.resolve(strict=False)
    except Exception:
        return None
    for root in WRITE_FOLDERS:
        root_r = Path(root).resolve()
        if r != root_r and root_r in r.parents:
            return r
    return None


def _confirm(title: str, detail: str) -> bool:
    print(f"\n{YEL}  {title}{RESET} {BOLD}{detail}{RESET}")
    try:
        return ask(prompt_text(f"{YEL}  Type 'yes' to allow: {RESET}")) == "yes"
    except EOFError:
        return False


def move_to_trash(path: str) -> str:
    target = _inside_write_folders(path)
    if not target:
        return "Refused: move_to_trash only works on files/folders inside Desktop, Documents or Downloads (not the folders themselves)."
    if not target.exists():
        return f"Nothing to trash: {target} does not exist. Check the path with ls first."
    kind = "folder" if target.is_dir() else "file"
    if not _confirm(f"🗑  Move this {kind} to the Trash (recoverable with Put Back):", str(target)):
        audit("DECLINED", f"trash {target}")
        return DECLINED_MSG
    r = subprocess.run(["/usr/bin/trash", str(target)], capture_output=True, text=True, timeout=30)
    audit("TRASHED" if r.returncode == 0 else "FAILED", f"trash {target}", r.stderr.strip()[:100])
    return f"Moved to Trash: {target}" if r.returncode == 0 else f"Could not move to Trash: {r.stderr.strip()}"


def move_file(source: str, destination: str) -> str:
    src, dst = _inside_write_folders(source), _inside_write_folders(destination)
    if not src or not dst:
        return "Refused: move_file only works inside Desktop, Documents or Downloads (for both source and destination)."
    if not src.exists():
        return f"Nothing to move: {src} does not exist. Check the path with ls first."
    if dst.is_dir():
        dst = dst / src.name
    if dst.exists():
        return f"Refused: {dst} already exists. move_file never overwrites; choose another name."
    if dst == src or src in dst.parents:
        return "Refused: can't move a folder into itself."
    if not dst.parent.exists():
        return f"Refused: the folder {dst.parent} doesn't exist. Create it first with mkdir -p."
    if not _confirm("📦 Move / rename:", f"{src}  →  {dst}"):
        audit("DECLINED", f"move {src} -> {dst}")
        return DECLINED_MSG
    import shutil
    shutil.move(str(src), str(dst))
    audit("MOVED", f"move {src} -> {dst}")
    return f"Moved: {src} → {dst}"


def audit(event: str, command: str, detail: str = ""):
    one_line = command.replace("\n", " ⏎ ")
    one_line = one_line if len(one_line) <= 400 else one_line[:400] + f" …(+{len(one_line) - 400} chars)"
    with AUDIT_LOG.open("a") as f:
        f.write(f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S}  {event:<9} {one_line}" + (f"  [{detail}]" if detail else "") + "\n")


def cap_audit_log(max_lines: int = 5000):
    if AUDIT_LOG.exists():
        lines = AUDIT_LOG.read_text(errors="replace").splitlines()
        if len(lines) > max_lines:
            AUDIT_LOG.write_text("\n".join(lines[-max_lines:]) + "\n")


# ----------------------------------------------------------------------------- memory

_CON = None


def db():
    """One shared connection (opening a new one for every call leaked file handles)."""
    global _CON
    if _CON is None:
        _CON = sqlite3.connect(DB)
        _CON.execute("CREATE VIRTUAL TABLE IF NOT EXISTS memories USING fts5(fact, ts UNINDEXED)")
    return _CON


def _norm(fact: str) -> set[str]:
    return set(re.findall(r"[a-z0-9+#]+", fact.lower()))


NAME_FACT = re.compile(r"\b(user'?s? name|name is|is named|call (me|them|the user)|user name)\b", re.I)


def known_name() -> str | None:
    for (f,) in db().execute("SELECT fact FROM memories ORDER BY rowid DESC"):
        if NAME_FACT.search(f):
            m = re.search(r"(?:name is|named|name:|call (?:me|them|the user))\s*([A-Z][\w'-]+)", f, re.I)
            if m:
                return m.group(1).capitalize()
    return None


def save_memory(fact: str, source: str = "user") -> str:
    """Save one fact. Skips junk and near-duplicates; a new name replaces the old one."""
    fact = re.sub(r"\s+", " ", fact).strip().strip("\"'").rstrip(".")
    if len(fact) < 4 or len(fact) > 300 or len(_norm(fact)) < 2:
        return "Not saved: a memory should be one short, clear fact (4-300 characters)."
    if source == "model" and (" | " in fact or re.match(r"(?i)(created|made|saved|downloaded|wrote|ran|generated|"
                                                         r"built|opened|moved|deleted|installed)\b", fact)):
        return ("Not saved: memories are for lasting facts about the user (name, preferences, projects), one per "
                "memory — not a log of what was just done.")
    con = db()
    words = _norm(fact)
    for rowid, old in con.execute("SELECT rowid, fact FROM memories").fetchall():
        ow = _norm(old)
        if words == ow or len(words & ow) / max(len(words | ow), 1) >= 0.8:
            return f"Already remembered (#{rowid}): {old}"
    if NAME_FACT.search(fact):     # a new name replaces any older name, however it was worded
        for rowid, old in con.execute("SELECT rowid, fact FROM memories").fetchall():
            if NAME_FACT.search(old):
                con.execute("DELETE FROM memories WHERE rowid = ?", (rowid,))
    con.execute("INSERT INTO memories VALUES (?, ?)", (fact, datetime.date.today().isoformat()))
    con.commit()
    return f"Saved to memory: {fact}"


def forget_memory(rowid: int) -> str:
    con = db()
    row = con.execute("SELECT fact FROM memories WHERE rowid = ?", (rowid,)).fetchone()
    if not row:
        return f"There is no memory #{rowid}. Type /memories to see the numbers."
    con.execute("DELETE FROM memories WHERE rowid = ?", (rowid,)); con.commit()
    return f"Forgotten #{rowid}: {row[0]}"


def list_memories() -> str:
    rows = db().execute("SELECT rowid, fact, ts FROM memories ORDER BY rowid").fetchall()
    if not rows:
        return "  (no memories yet — say \"remember that ...\" or use /remember <fact>)"
    return "\n".join(f"  {i}. {f}  {DIM}({t}){RESET}" for i, f, t in rows) + f"\n  {DIM}{len(rows)} memories · /forget <number> to remove one{RESET}"


def core_memories(k: int = 12) -> list[str]:
    """Newest facts, loaded into the system prompt once per session."""
    return [f for (f,) in db().execute("SELECT fact FROM memories ORDER BY rowid DESC LIMIT ?", (k,))][::-1]


def recall(text: str, k: int = 6) -> list[str]:
    """Hybrid of 'always-on core memory' (newest facts) and keyword search on the current message."""
    con = db()
    newest = [f for (f,) in con.execute("SELECT fact FROM memories ORDER BY rowid DESC LIMIT 4")]
    words = [w for w in re.findall(r"\w+", text.lower()) if len(w) > 3][:12]
    found = []
    if words:
        try:
            found = [f for (f,) in con.execute("SELECT fact FROM memories WHERE memories MATCH ? ORDER BY bm25(memories) LIMIT ?",
                                               (" OR ".join(f'"{w}"' for w in words), k))]
        except sqlite3.OperationalError:
            pass
    return list(dict.fromkeys(found + newest))[:k]


# ----------------------------------------------------------------------------- sessions
SESSIONS = DATA / "sessions"
KEEP_SESSIONS = 30


def new_session_path() -> Path:
    return SESSIONS / f"{datetime.datetime.now():%Y-%m-%d_%H-%M-%S}.json"


def _title(history: list[dict]) -> str:
    for m in history:
        if m["role"] == "user" and not m["content"].startswith("[Harness") and not m["content"].startswith("[Step"):
            t = re.sub(r"^\[Memory —[^\]]*\]\n", "", m["content"]).split("\n(This was saved")[0].strip()
            return t[:60] + ("…" if len(t) > 60 else "")
    return "(empty)"


def save_session(path: Path, history: list[dict]):
    """Auto-save after every turn (small JSON file, local only)."""
    if not any(m["role"] == "user" for m in history):
        return
    SESSIONS.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps({"title": _title(history), "updated": f"{datetime.datetime.now():%Y-%m-%d %H:%M}",
                               "history": history}, ensure_ascii=False))
    tmp.replace(path)
    for old in sorted(SESSIONS.glob("*.json"))[:-KEEP_SESSIONS]:
        old.unlink(missing_ok=True)


def list_sessions() -> list[tuple[Path, dict]]:
    out = []
    for f in sorted(SESSIONS.glob("*.json"), reverse=True)[:10] if SESSIONS.exists() else []:
        try:
            out.append((f, json.loads(f.read_text())))
        except Exception:
            continue
    return out


def show_sessions(current: Path) -> str:
    rows = list_sessions()
    if not rows:
        return "  (no saved sessions yet — every chat is saved automatically)"
    return "\n".join(f"  {i}. {d.get('updated', '?')}  {d.get('title', '')}  {DIM}({len(d.get('history', []))} msgs)"
                     f"{' ← this chat' if f == current else ''}{RESET}" for i, (f, d) in enumerate(rows, 1)) + \
        f"\n  {DIM}/resume <number> to continue one{RESET}"


# ----------------------------------------------------------------------------- tools

SEARCH_BACKENDS = ["duckduckgo", "bing", "yahoo", "google"]
UNSURE = re.compile(r"not (a )?(widely|well)[- ]known|(isn't|is not|not) (sure|familiar|aware)|(don't|do not) (have|know)"
                    r"|couldn't find|could not find|no (information|info|results)|can you (clarify|provide)|could you "
                    r"(clarify|provide|share)|more context|not certain|unclear what|i'm not able to find", re.I)
STATE = {"question": ""}      # the user's current message, used to rank web passages by relevance
STOP = set("the a an and or of to in on for is are was were be been with as at by from that this it its what which who "
           "how why when where does do did can could would should will i you me my your about into than then there "
           "their them they he she his her we our us not no yes if so".split())


def _run(cmd: list[str]) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception:
        return ""


def system_info() -> str:
    """RAM, disk, CPU, battery and top apps from fixed, read-only macOS commands (no approval needed)."""
    import shutil
    total = int(_run(["sysctl", "-n", "hw.memsize"]) or 0)
    vm = _run(["vm_stat"])
    page = int(re.search(r"page size of (\d+)", vm).group(1)) if "page size" in vm else 16384
    pages = {k.strip().lower(): int(v.strip(" .")) for k, v in re.findall(r"^(.+?):\s+(\d+)\.", vm, re.M)}
    gb = lambda n: n / 1024**3
    free = (pages.get("pages free", 0) + pages.get("pages speculative", 0)) * page
    reclaim = (pages.get("pages inactive", 0) + pages.get("pages purgeable", 0)) * page
    used = (pages.get("pages active", 0) + pages.get("pages wired down", 0)
            + pages.get("pages occupied by compressor", 0)) * page
    pressure = re.search(r"free percentage: (\d+)%", _run(["memory_pressure"]))
    swap = _run(["sysctl", "-n", "vm.swapusage"])
    d = shutil.disk_usage("/System/Volumes/Data")
    load = ", ".join(f"{x:.2f}" for x in __import__("os").getloadavg())
    top = _run(["ps", "-Ao", "rss=,comm=", "-m"]).splitlines()[:5]
    top_txt = "; ".join(f"{Path(c.split(None, 1)[1]).name} {int(c.split()[0]) / 1024**2:.1f} GB" for c in top if c.strip())
    batt = re.search(r"(\d+%;[^;]*;?[^\n]*)", _run(["pmset", "-g", "batt"]))
    avail = (f"{pressure.group(1)}% ≈ {gb(total) * int(pressure.group(1)) / 100:.1f} GB" if pressure
             else f"≈ {gb(free + reclaim):.1f} GB")
    return (f"RAM: {gb(total):.0f} GB total. AVAILABLE for apps right now (macOS estimate): {avail}. In use: "
            f"{gb(used):.1f} GB. (Detail: {gb(free):.1f} GB untouched + {gb(reclaim):.1f} GB cache macOS frees on demand.)\n"
            f"Swap: {swap}\n"
            f"Disk (main volume): {gb(d.free):.0f} GB free of {gb(d.total):.0f} GB\n"
            f"CPU: {_run(['sysctl', '-n', 'machdep.cpu.brand_string'])}, {_run(['sysctl', '-n', 'hw.ncpu'])} cores, "
            f"load average {load}\n"
            f"Battery: {batt.group(1).strip() if batt else 'no battery info'}\n"
            f"Uptime: {_run(['uptime']).split(',')[0].split('up')[-1].strip()}\n"
            f"Top memory apps: {top_txt}")


def _public(url: str) -> bool:
    p = urlparse(url)
    if p.scheme not in ("http", "https") or not p.hostname:
        return False
    try:
        return all(not (ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved)
                   for ip in (ipaddress.ip_address(i[4][0]) for i in socket.getaddrinfo(p.hostname, None)))
    except (socket.gaierror, ValueError):
        return False


def _fetch_text(url: str, timeout: float = 8) -> str:
    import trafilatura
    if not _public(url):
        return ""
    try:
        r = httpx.get(url, timeout=timeout, follow_redirects=True,
                      headers={"User-Agent": "Mozilla/5.0 (Macintosh; Mini local assistant)"})
        if "text/html" not in r.headers.get("content-type", "text/html"):
            return ""
        return trafilatura.extract(r.text[:1_500_000], include_comments=False, favor_precision=True) or ""
    except Exception:
        return ""


def _terms(text: str) -> list[str]:
    return [w for w in re.findall(r"[a-z0-9]+", text.lower()) if w not in STOP and len(w) > 1]


def _passages(text: str, size: int = 450) -> list[str]:
    """Split page text into ~450-char passages on paragraph/sentence boundaries."""
    out, cur = [], ""
    for para in re.split(r"\n+", text):
        for sent in re.split(r"(?<=[.!?])\s+", para.strip()):
            if len(cur) + len(sent) > size and cur:
                out.append(cur.strip()); cur = ""
            cur += sent + " "
        if len(cur) > size * 0.6:
            out.append(cur.strip()); cur = ""
    if cur.strip():
        out.append(cur.strip())
    return [p for p in out if len(p) > 60]


def _rank(passages: list[tuple[int, str]], query: str, k: int, per_source: int = 2, extra: str = "") -> list[tuple[int, str]]:
    """BM25 over passages, tuned for search: joined-word matching ("dark hub" = "DarkHub"), an exact-phrase bonus,
    and a coverage penalty so a passage matching only one query word ("dark") can't win. Pure Python, no models."""
    import math
    core = [w for w in _terms(query)]
    joined = {a + b for a, b in zip(core, core[1:])}                       # dark hub -> darkhub
    q = set(core) | joined | set(_terms(extra))
    words = re.findall(r"[A-Za-z0-9]+", query)
    phrase = re.compile(r"[\s\-_.]*".join(map(re.escape, words)), re.I) if words else None
    docs = [(src, p, _terms(p)) for src, p in passages]
    if not docs or not q:
        return passages[:k]
    avg = sum(len(t) for _, _, t in docs) / len(docs)
    df = {w: sum(1 for _, _, t in docs if w in t) for w in q}
    def score(src, p, terms):
        s = 0.0
        for w in q:
            f = terms.count(w)
            if f:
                idf = math.log(1 + (len(docs) - df[w] + 0.5) / (df[w] + 0.5))
                s += idf * f * 2.2 / (f + 1.2 * (0.25 + 0.75 * len(terms) / avg))
        if core:
            covered = sum(1 for w in set(core) if w in terms) / len(set(core))
            if any(j in terms for j in joined):
                covered = 1.0
            s *= 0.25 + 0.75 * covered ** 2
        if phrase and phrase.search(p):
            s += 3.0
        return s * (1.15 - 0.05 * src)
    scored = sorted(((score(src, p, t), src, p) for src, p, t in docs), reverse=True)
    picked, count = [], {}
    # first pass: the best passage from each source (diversity), second pass: fill up with the best remaining
    for sc, src, p in scored:
        if sc > 0.5 and src not in count:
            picked.append((src, p)); count[src] = 1
    picked = picked[:k]  # already in score order
    for sc, src, p in scored:
        if len(picked) >= k or sc <= 0.5:
            break
        if (src, p) not in picked and count.get(src, 0) < per_source:
            picked.append((src, p)); count[src] = count.get(src, 0) + 1
    return picked


def web_search(query: str) -> str:
    """Search -> fetch the top pages in parallel -> keep only the best passages (fixed ~3k-char budget)."""
    from concurrent.futures import ThreadPoolExecutor
    from ddgs import DDGS
    hits, errors = [], []
    for backend in SEARCH_BACKENDS:     # merge engines until there are 5+ different sites (one may be rate-limited)
        try:
            hits += DDGS().text(query, max_results=8, backend=backend) or []
        except Exception as e:
            errors.append(f"{backend}: {e}")
        if len({urlparse(h.get("href", "")).netloc for h in hits}) >= 5:
            break
    if not hits:
        return "Search failed on every engine (" + "; ".join(errors)[:200] + "). Tell the user to try again shortly."
    seen, results = set(), []
    for h in hits:                                   # one result per site, so one site can't crowd out others
        dom = urlparse(h.get("href", "")).netloc.removeprefix("www.")
        if dom and dom not in seen:
            seen.add(dom); results.append(h)
    if not results:
        return ("No results. [Try ONE different, shorter query (e.g. fewer words or the key name only), or tell the "
                "user nothing was found. Don't guess.]")
    top = results[:4]
    with ThreadPoolExecutor(4) as ex:
        pages = list(ex.map(lambda h: _fetch_text(h["href"]), top))
    pool = []
    for i, (h, text) in enumerate(zip(top, pages)):
        pool.append((i, f"{h.get('title', '')}. {h.get('body', '')}"))        # the snippet always counts
        pool += [(i, p) for p in _passages(text)[:40]]
    best = _rank(pool, query, k=6, extra=STATE["question"])
    if not best:   # nothing matched well: fall back to the plain search snippets rather than returning nothing
        best = [(i, f"{h.get('title', '')}. {h.get('body', '')}") for i, h in enumerate(top)]
    used = sorted({src for src, _ in best})
    num = {src: n for n, src in enumerate(used, 1)}
    lines = [f"Evidence for: {query}"]
    for src in used:
        lines.append(f"\n[{num[src]}] {top[src].get('title', '')} — {top[src]['href']}")
        lines += [f"  • {p}" for s, p in best if s == src]
    others = [f"{h.get('title', '')} ({urlparse(h['href']).netloc})" for h in results[4:7]]
    if others:
        lines.append("\nOther result titles (NOT read, unverified — only mention if the user asks for more): " + "; ".join(others))
    return "\n".join(lines)[:3500]


def read_webpage(url: str) -> str:
    if not _public(url):
        return "Blocked: only public http(s) web pages can be read."
    text = _fetch_text(url, timeout=15)
    if not text:
        return ("Could not load readable text from that page (it may need JavaScript or a login). [Use web_search "
                "results or another URL instead. Don't guess the page's content.]")
    best = _rank([(0, p) for p in _passages(text)], STATE["question"] or text[:200], k=7, per_source=7)
    order = {p: i for i, p in enumerate(_passages(text))}
    return f"[{url}]\n" + "\n".join(f"  • {p}" for _, p in sorted(best, key=lambda b: order.get(b[1], 0)))[:3000]


def run_command(command: str) -> str:
    command = command.strip()
    kind, reason = check_command(command)
    if kind == "blocked":
        print(f"\n{YEL}  ⛔ Blocked permanently (it {reason}):{RESET} {command}")
        audit("BLOCKED", command, reason)
        hint = SAFE_HINTS.get(reason, "")
        return (f"Refused: this command {reason}, which is blocked. This does NOT mean the task is impossible: "
                f"if the user's goal can be done WITHOUT that part, retry right away with a simpler command. {hint} "
                "You CAN create folders (mkdir -p), files (printf > file), copy (cp), move/rename (move_file tool) and "
                "delete to the Trash (move_to_trash tool) inside Desktop, Documents and Downloads, and download or "
                "install with curl/git/brew/pip/npm. Only if the goal itself needs the blocked action, tell the user "
                "plainly and give them the exact command to run themselves, using exact paths from this conversation.")

    print(f"\n{YEL}  Mini wants to run:{RESET} {BOLD}{command}{RESET}")
    if kind == "read-only":
        prompt, needed = f"{YEL}  Read-only. Allow? [y/N] {RESET}", ("y", "yes")
    else:
        label = {"network": "🌐 Uses the internet (downloads only — uploads are blocked). Check the URL.",
                 "install": "📦 Installs/changes software (internet + package folders, up to 5 min). Check it.",
                 }.get(kind, "✏️  Can create or change files in Desktop, Documents, Downloads (never delete). Check it.")
        print(f"{YEL}  {label}{RESET}")
        prompt, needed = f"{YEL}  Type 'yes' to allow: {RESET}", ("yes",)
    try:
        ok = ask(prompt_text(prompt)) in needed
    except EOFError:
        ok = False
    if not ok:
        audit("DECLINED", command)
        return DECLINED_MSG
    WORKSPACE.mkdir(exist_ok=True)
    backup_note = backup_files(overwrite_targets(command)) if kind != "read-only" else ""
    env = {"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": H,
           "LANG": "en_US.UTF-8", "TERM": "dumb", "GIT_OPTIONAL_LOCKS": "0", "PAGER": "cat",
           "GIT_PAGER": "cat", "TMPDIR": "/private/tmp/"}   # no inherited tokens or API keys
    try:
        limit = 300 if kind == "install" else 120 if kind == "network" else 60
        p = run_killable(["/usr/bin/sandbox-exec", "-p", sandbox_profile(kind), "/bin/zsh", "-f", "-c", command], env, limit)
        out = (p.stdout + ("\n[stderr]\n" + p.stderr if p.stderr.strip() else "")).strip() or "(no output)"
        audit("RAN", command, f"exit {p.returncode}")
        if "ot permitted" in out:
            out += ("\n[Note: the sandbox blocked part of this. Mini can't delete/rename files, write outside Desktop/"
                    "Documents/Downloads, control other apps or read private folders; only downloads/installs get the network.]")
        return (f"exit code {p.returncode}\n{out[:3000]}" + result_hint(command, p.returncode, p.stdout)
                + (verify_created(command) if p.returncode == 0 else "") + backup_note)
    except subprocess.TimeoutExpired:
        audit("TIMEOUT", command)
        return "Command timed out (interactive commands like top or less need -l 1 or cat; installs get 5 minutes)."


# ----------------------------------------------------------------------------- file tools
# Direct Python tools instead of shell heredocs: no quoting mistakes, exact checks, backups, clear errors.
# Research: search/replace edits fail loudly (never silently corrupt); whole-file write is the fallback.

TEXT_LIMIT = 12_000            # characters returned by read_file per call (use start_line for more)
SKIP_DIRS = {".git", "node_modules", ".venv", "venv", "__pycache__", ".next", "dist", "build", ".cache", "Library"}
RISKY_OPEN = {".app", ".command", ".sh", ".zsh", ".bash", ".pkg", ".dmg", ".terminal", ".scpt", ".workflow", ".tool",
              ".jar", ".py", ".pl", ".rb", ".action", ".scptd", ".mpkg", ".prefPane", ".kext"}


def _resolve(path: str) -> Path:
    p = Path(path.strip().strip("'\"")).expanduser()
    return (p if p.is_absolute() else Path.home() / p).resolve(strict=False)


def _is_secret(p: Path) -> bool:
    return any(p == Path(s) or Path(s) in p.parents for s in SECRET_PATHS)


def _short(p: Path) -> str:
    return f"~/{p.relative_to(Path.home())}" if Path.home() in p.parents else str(p)


def read_file(path: str, start_line: int = 1) -> str:
    """Text, code, PDF (pypdf), Word/RTF/ODT (macOS textutil). Numbered lines so edits can be precise."""
    p = _resolve(path)
    if _is_secret(p):
        return "Refused: that is a private folder (keys, passwords, mail, browser data)."
    if not p.exists():
        near = find_files(p.stem or p.name, limit=3)
        return f"Not found: {_short(p)}. [Did you mean one of these?]\n{near}"
    outside = _inside_write_folders(str(p)) is None
    what = "folder" if p.is_dir() else "file"
    if (outside or STATE.get("web_used")) and not _confirm_y(
            f"📖 Read this {what}{'' if outside else ' (web content was read this turn)'}:", _short(p)):
        return DECLINED_MSG
    if p.is_dir():
        items = sorted(p.iterdir(), key=lambda x: (not x.is_dir(), x.name.lower()))[:60]
        return f"{_short(p)} is a folder:\n" + "\n".join(f"  {'📁' if i.is_dir() else '📄'} {i.name}" for i in items)
    ext = p.suffix.lower()
    try:
        if ext == ".pdf":
            from pypdf import PdfReader
            reader = PdfReader(str(p), strict=False)   # tolerate slightly damaged real-world PDFs
            text = "\n".join(f"--- page {i + 1} ---\n{(pg.extract_text() or '').strip()}" for i, pg in enumerate(reader.pages[:60]))
        elif ext in (".docx", ".doc", ".rtf", ".rtfd", ".odt", ".wordml", ".webarchive"):
            text = subprocess.run(["/usr/bin/textutil", "-convert", "txt", "-stdout", str(p)],
                                  capture_output=True, text=True, timeout=30).stdout
        else:
            raw = p.read_bytes()[:2_000_000]
            if b"\x00" in raw[:4096]:
                return f"{_short(p)} is a binary file ({p.stat().st_size // 1024} KB); it can't be read as text."
            text = raw.decode("utf-8", errors="replace")
    except Exception as e:
        return f"Could not read {_short(p)}: {e}"
    lines = text.splitlines()
    start = max(1, int(start_line or 1))
    out, size = [], 0
    for n, line in enumerate(lines[start - 1:], start):
        row = f"{n:>4}| {line}"
        if size + len(row) > TEXT_LIMIT:
            out.append(f"... [{len(lines) - n + 1} more lines — call read_file with start_line={n}]")
            break
        out.append(row); size += len(row) + 1
    return f"{_short(p)} ({len(lines)} lines)\n" + "\n".join(out) if out else f"{_short(p)} is empty."


def _diff(old: str, new: str, name: str, limit: int = 30) -> str:
    import difflib
    d = list(difflib.unified_diff(old.splitlines(), new.splitlines(), name, name, n=1, lineterm=""))[2:]
    return "\n".join(d[:limit]) + (f"\n... (+{len(d) - limit} more diff lines)" if len(d) > limit else "")


def _show_diff(text: str):
    for line in text.splitlines():
        color = "\033[32m" if line.startswith("+") else "\033[31m" if line.startswith("-") else DIM
        print(f"    {color}{line}{RESET}")


def write_file(path: str, content: str) -> str:
    """Create or fully replace a text file inside Desktop/Documents/Downloads (backup first, needs 'yes')."""
    p = _inside_write_folders(path)
    if not p:
        return "Refused: write_file only works inside Desktop, Documents or Downloads."
    if p.exists() and p.is_dir():
        return f"Refused: {_short(p)} is a folder. Give a file path."
    if not p.parent.exists():
        return f"Refused: the folder {_short(p.parent)} doesn't exist. Create it first (run_command: mkdir -p ...)."
    content = content if content.endswith("\n") else content + "\n"
    if p.exists():
        old = p.read_text(errors="replace")
        if old == content:
            return f"No change: {_short(p)} already has exactly this content."
        print(f"\n{YEL}  ✏️  Replace the whole file{RESET} {BOLD}{_short(p)}{RESET} {DIM}({len(old.splitlines())} → {len(content.splitlines())} lines){RESET}")
        _show_diff(_diff(old, content, p.name, 12))
    else:
        print(f"\n{YEL}  📝 Create{RESET} {BOLD}{_short(p)}{RESET} {DIM}({len(content.splitlines())} lines, {len(content)} chars){RESET}")
        for line in content.splitlines()[:6]:
            print(f"    {DIM}{line[:110]}{RESET}")
    if not _confirm_yes():
        audit("DECLINED", f"write_file {p}")
        return DECLINED_MSG
    note = backup_files([p]) if p.exists() else ""
    p.write_text(content)
    audit("WROTE", f"write_file {p}", f"{len(content)} chars")
    return f"Wrote {_short(p)} ({len(content.splitlines())} lines). [Verified: file exists.]" + note


def _find_block(text: str, old: str) -> tuple[int, int, str]:
    """Locate old_text: exact first, then ignoring trailing spaces/indentation. Returns (start, end, how)."""
    i = text.find(old)
    if i != -1:
        return (i, i + len(old), "exact") if text.count(old) == 1 else (-2, -2, "many")
    lines, want = text.splitlines(keepends=True), [l.strip() for l in old.strip("\n").splitlines()]
    hits = []
    for s in range(len(lines) - len(want) + 1):
        if all(lines[s + k].strip() == want[k] for k in range(len(want))):
            hits.append(s)
    if len(hits) == 1:
        a = sum(len(l) for l in lines[:hits[0]])
        return a, a + sum(len(l) for l in lines[hits[0]:hits[0] + len(want)]), "whitespace-tolerant"
    return (-2, -2, "many") if hits else (-1, -1, "none")


def _closest(text: str, old: str) -> str:
    import difflib
    lines = text.splitlines()
    n = max(1, len(old.strip().splitlines()))
    best, at = 0.0, 0
    first = old.strip().splitlines()[0].strip() if old.strip() else ""
    for s in range(0, max(1, len(lines) - n + 1)):
        r = difflib.SequenceMatcher(None, first, lines[s].strip()).ratio()
        if r > best:
            best, at = r, s
    return "\n".join(f"{k + 1:>4}| {lines[k]}" for k in range(at, min(len(lines), at + n + 2)))


def edit_file(path: str, old_text: str, new_text: str) -> str:
    """Replace one exact passage in a text file (search/replace). Fails loudly instead of guessing."""
    p = _inside_write_folders(path)
    if not p:
        return "Refused: edit_file only works inside Desktop, Documents or Downloads."
    if not p.is_file():
        return f"Not found: {_short(p)}. Use find_files to get the exact path."
    if not old_text.strip():
        return "Refused: old_text is empty. To create or fully replace a file use write_file."
    text = p.read_text(errors="replace")
    a, b, how = _find_block(text, old_text)
    if how == "many":
        return "Edit not applied: old_text appears more than once. Include a few more surrounding lines so it is unique."
    if how == "none":
        return ("Edit not applied: old_text was not found in the file. The closest lines are:\n" + _closest(text, old_text)
                + "\n[Copy the exact current text from read_file (without the line numbers) and try again.]")
    new = text[:a] + new_text + text[b:]
    print(f"\n{YEL}  ✏️  Edit{RESET} {BOLD}{_short(p)}{RESET} {DIM}({how} match){RESET}")
    _show_diff(_diff(text, new, p.name))
    if not _confirm_yes():
        audit("DECLINED", f"edit_file {p}")
        return DECLINED_MSG
    note = backup_files([p])
    p.write_text(new)
    audit("EDITED", f"edit_file {p}", how)
    return f"Edited {_short(p)} ({how} match). [Verified: change saved.]" + note


def find_files(query: str, folder: str = "", limit: int = 10) -> str:
    """Fuzzy file-name search in Desktop/Documents/Downloads (skips .git, node_modules, venvs). Newest first on ties."""
    import difflib, os, time
    roots = [_resolve(folder)] if folder else [Path(f) for f in WRITE_FOLDERS]
    if folder and (Path.home() not in roots[0].parents and roots[0] != Path.home() or _is_secret(roots[0])):
        return "Refused: find_files searches inside your home folder only (not private folders)."
    q = re.sub(r"[^a-z0-9]+", " ", query.lower()).strip()
    words = q.split()
    if not words:
        return "Give a name or part of a name to search for."
    scored, scanned, t0 = [], 0, time.time()
    for root in roots:
        if _is_secret(root) or not root.exists():
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")
                           and not _is_secret(Path(dirpath) / d)]
            if dirpath.count(os.sep) - str(root).count(os.sep) >= 5:
                dirnames[:] = []
            for name in filenames + dirnames:
                scanned += 1
                n = re.sub(r"[^a-z0-9]+", " ", name.lower())
                hit = sum(1 for w in words if w in n) / len(words)
                score = hit * 2 + difflib.SequenceMatcher(None, q, n).ratio()
                if hit > 0 or score > 0.75:
                    full = Path(dirpath) / name
                    try:
                        mtime = full.stat().st_mtime
                    except OSError:
                        continue
                    scored.append((score, mtime, full))
            if scanned > 40_000 or time.time() - t0 > 4:
                break
    if not scored:
        return f"No files matching '{query}' in {', '.join(_short(r) for r in roots)}."
    scored.sort(key=lambda x: (-x[0], -x[1]))
    return "\n".join(f"  {'📁' if f.is_dir() else '📄'} {_short(f)}  (modified {datetime.datetime.fromtimestamp(m):%d %b %H:%M})"
                     for _, m, f in scored[:limit])


def open_file(path: str) -> str:
    """Open a file/folder in its default app (HTML in the browser). Never opens apps or scripts."""
    p = _inside_write_folders(path)
    if not p or not p.exists():
        return "Refused: open_file only opens existing files/folders inside Desktop, Documents or Downloads."
    if p.suffix.lower() in RISKY_OPEN or (p.is_file() and os_access_exec(p) and p.suffix == ""):
        return f"Refused: {p.suffix or 'that file'} files run programs. Open it yourself from Finder if you trust it."
    if not _confirm_y("👀 Open in its default app:", _short(p)):
        return DECLINED_MSG
    r = subprocess.run(["/usr/bin/open", str(p)], capture_output=True, text=True, timeout=15)
    audit("OPENED", f"open {p}", f"exit {r.returncode}")
    return f"Opened {_short(p)}." if r.returncode == 0 else f"Could not open: {r.stderr.strip()}"


def os_access_exec(p: Path) -> bool:
    import os
    return os.access(p, os.X_OK)


def clipboard(action: str, text: str = "") -> str:
    """Read (needs 'y': the clipboard can hold passwords) or write the macOS clipboard."""
    if action == "write":
        if not text:
            return "Nothing to copy."
        subprocess.run(["/usr/bin/pbcopy"], input=text, text=True, timeout=5)
        print(f"{DIM}  📋 copied {len(text)} characters to the clipboard{RESET}")
        return f"Copied {len(text)} characters to the clipboard."
    if action == "read":
        if not _confirm_y("📋 Let Mini read your clipboard:", "(it may contain private text)"):
            return DECLINED_MSG
        clip = subprocess.run(["/usr/bin/pbpaste"], capture_output=True, text=True, timeout=5).stdout
        return (clip[:6000] + ("\n...[truncated]" if len(clip) > 6000 else "")) if clip.strip() else "The clipboard is empty."
    return "Use action 'read' or 'write'."


def _confirm_yes() -> bool:
    try:
        return ask(prompt_text(f"{YEL}  Type 'yes' to allow: {RESET}")) == "yes"
    except EOFError:
        return False


def _confirm_y(title: str, detail: str) -> bool:
    print(f"\n{YEL}  {title}{RESET} {BOLD}{detail}{RESET}")
    try:
        return ask(prompt_text(f"{YEL}  Allow? [y/N] {RESET}")) in ("y", "yes")
    except EOFError:
        return False


# ----------------------------------------------------------------------------- voice (/talk)
# Fully local: Moonshine v2 Small Streaming listens (mic + built-in voice detection, ~0.5 GB RAM only while /talk
# is on), the usual model thinks, macOS `say` speaks sentence by sentence. Nothing leaves the Mac, no limits.

class Speaker:
    """Speaks the reply sentence by sentence while it is still being generated. Enter interrupts."""
    def __init__(self):
        import queue, threading
        self.q, self.buf, self.proc, self.in_code, self.said_code = queue.Queue(), "", None, False, False
        self.stopped = False
        threading.Thread(target=self._run, daemon=True).start()

    @staticmethod
    def clean(text: str) -> str:
        text = re.sub(r"https?://\S+", "link", text)
        for a, b in (("≈", " about "), ("~", " about "), ("→", " to "), ("&", " and "), ("e.g.", "for example"),
                     ("i.e.", "that is"), ("vs.", "versus"), ("%", " percent")):
            text = text.replace(a, b)
        text = re.sub(r"`([^`]*)`", r"\1", text)
        text = re.sub(r"[*_#~]+", "", text)
        text = re.sub(r"[>|]+", " ", text)
        text = re.sub(r"\[(\d+)\]", "", text)                 # citation numbers
        text = re.sub(r"^\s*[-•]\s+", "", text, flags=re.M)
        text = re.sub(r"\s+([.,!?;:])", r"\1", re.sub(r"\s+", " ", text))
        return text.strip()

    def feed(self, chunk: str):
        self.buf += chunk
        while True:
            if "```" in self.buf:                                 # don't read code aloud
                before, _, after = self.buf.partition("```")
                if not self.in_code:          # text before an opening fence is speech; inside a block it's code
                    self._push(before)
                if not self.in_code and not self.said_code:
                    self._push("I've put the code on screen.")
                    self.said_code = True
                self.in_code, self.buf = not self.in_code, after
                continue
            if self.in_code:
                self.buf = self.buf[-3:]
                return
            m = re.search(r"(.+?[.!?])(\s+|$)|(.+?)\n\s*\n", self.buf, re.S)
            if not m or (m.group(1) and m.end() == len(self.buf) and not self.buf.endswith((" ", "\n"))):
                return
            self._push(m.group(1) or m.group(3))
            self.buf = self.buf[m.end():]

    def flush(self):
        if not self.in_code:
            self._push(self.buf)
        self.buf, self.in_code = "", False

    def _push(self, text: str):
        t = self.clean(text)
        if t and re.search(r"\w", t) and not self.stopped:
            self.q.put(t)

    def _run(self):
        while True:
            text = self.q.get()
            if self.stopped:
                continue
            self.proc = subprocess.Popen(["/usr/bin/say", text])
            self.proc.wait()
            self.proc = None

    def busy(self) -> bool:
        return not self.q.empty() or self.proc is not None

    def stop(self):
        self.stopped = True
        while not self.q.empty():
            self.q.get_nowait()
        if self.proc:
            self.proc.terminate()
        self.buf, self.in_code = "", False

    def reset(self):
        self.stopped, self.said_code = False, False

    def wait(self):
        """Let Mini finish speaking; Enter interrupts."""
        import select, time
        while self.busy():
            r, _, _ = select.select([sys.stdin], [], [], 0.1)
            if r:
                sys.stdin.readline()
                self.stop()
                print(f"{DIM}  (stopped speaking){RESET}")
                break
        time.sleep(0.15)


class Listener:
    """Microphone -> text with Moonshine (built-in voice-activity detection decides when you've finished)."""
    def __init__(self, keyterms: list[str]):
        import queue
        from moonshine_voice import ModelArch
        from moonshine_voice.mic_transcriber import MicTranscriber
        self.lines = queue.Queue()
        self.errors = queue.Queue()
        self.mic = (MicTranscriber().language("en").model_arch(ModelArch.SMALL_STREAMING)
                    .on_text(lambda t: print(f"\r\033[K{DIM}  🎤 {t}{RESET}", end="", flush=True))
                    .on_line(lambda line: self.lines.put(getattr(line, "text", "") or ""))
                    .on_error(lambda e: self.errors.put(e)))
        self.mic.load()
        self.mic.set_keyterms(keyterms)
        self.mic.mute(True)
        self.mic.start()

    def listen(self) -> str | None:
        """Wait for one spoken line. A typed line is used instead; Ctrl-C leaves talk mode."""
        import queue, select
        while not self.lines.empty():
            self.lines.get_nowait()
        self.mic.mute(False)
        print(f"{DIM}  🎤 listening… (speak, or type and press Enter){RESET}", end="", flush=True)
        try:
            while True:
                if not self.errors.empty():
                    raise RuntimeError(self.errors.get())
                try:
                    text = self.lines.get(timeout=0.1).strip()
                    if re.search(r"\w", text):
                        print(f"\r\033[K{BOLD}you ›{RESET} {text}  {DIM}(heard){RESET}")
                        return text
                except queue.Empty:
                    pass
                r, _, _ = select.select([sys.stdin], [], [], 0)
                if r:
                    typed = sys.stdin.readline().strip()
                    print("\r\033[K", end="")
                    if typed:
                        return typed
        finally:
            self.mic.mute(True)

    def close(self):
        try:
            self.mic.stop(); self.mic.close()
        except Exception:
            pass


def start_talk(name: str | None):
    print(f"{DIM}  loading the speech model…{RESET}")
    try:
        listener = Listener(["Mini", "Mac", "RAM", "Desktop", "Documents", "Downloads", "Ollama"] + ([name] if name else []))
    except Exception as e:
        hint = ("Allow microphone access: System Settings → Privacy & Security → Microphone → turn on Terminal, then "
                "restart Terminal." if "microphone" in str(e).lower() or "portaudio" in str(e).lower() or "device" in str(e).lower()
                else "Check that moonshine-voice is installed in Mini's environment.")
        print(f"{YEL}  Couldn't start voice mode: {e}\n  {hint}{RESET}")
        return None, None
    print(f"{DIM}  🗣  talk mode ON — speak naturally. Mini answers out loud. Press Enter to interrupt it. "
          f"Approvals are still typed. Say 'stop talking' or type /talk to turn it off.{RESET}")
    return listener, Speaker()


STOP_TALK = re.compile(r"^\W*(stop talking|exit talk( mode)?|stop talk mode|end talk mode|turn off talk( mode)?|"
                       r"goodbye mini|bye mini)\W*$", re.I)


def run_killable(argv: list[str], env: dict, limit: int) -> subprocess.CompletedProcess:
    """Like subprocess.run, but a timeout kills the command AND everything it started (e.g. brew's helpers)."""
    import os, signal
    proc = subprocess.Popen(argv, cwd=Path.home(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
                            stdin=subprocess.DEVNULL, start_new_session=True)
    try:
        out, err = proc.communicate(timeout=limit)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.communicate()
        raise
    return subprocess.CompletedProcess(argv, proc.returncode, out, err)


def guarded_call(name: str, args: dict, seen: dict) -> str:
    """Repetition breaker (Mingbird-style): same tool + same arguments again gets the earlier result back instead of
    re-running it, a third time is refused, and 4+ uses of one tool in a single message triggers a nudge."""
    sig = name + json.dumps(args, sort_keys=True)
    changes = name in ("move_file", "move_to_trash", "write_file", "edit_file") or (
        name == "run_command" and check_command(args.get("command", ""))[0] not in ("read-only", "blocked"))
    if changes:   # the Mac changed: earlier results (ls, system_info...) may be stale, so allow re-checking
        for k in [k for k in seen if k.startswith(("run_command", "system_info"))]:
            del seen[k]
    count = seen.get(sig, (0, ""))[0] + 1
    uses = sum(1 for k in seen if k.startswith(name + "{")) + 1
    if count == 2:
        seen[sig] = (2, seen[sig][1])
        print(f"{DIM}  🔁 same {name} call repeated — reusing the earlier result{RESET}")
        return (seen[sig][1][:1500] + "\n[You already made this exact call; this is the same result. Do something "
                "different (other arguments or another tool) or answer the user now.]")
    if count >= 3:
        print(f"{DIM}  ⛔ stopped a repeated {name} call{RESET}")
        return "[Refused: you have repeated this exact call 3 times. Stop and answer the user with what you have.]"
    result = call_tool(name, args)
    seen[sig] = (1, result)
    if uses >= 4:
        result += (f"\n[Note: you have used {name} {uses} times for this one message. Unless the next step is clearly "
                   "different, stop and answer the user now.]")
    return result


BACKUPS = WORKSPACE / "backups"
DECLINED_MSG = ("The user said NO to this action. That is their choice, not a limitation: do not retry it and do not "
                "claim you are unable to do it. Briefly acknowledge, and ask if they want something else.")
ACTION_REQUEST = re.compile(r"\b(create|make|list|show|check|find|copy|install|download|clone|run|open|rename|move|"
                            r"delete|remove|trash|write|save|count|organi[sz]e|put|add)\b", re.I)
MAC_TARGET = re.compile(r"\b(folder|file|directory|dir|desktop|documents|downloads|repo|git|package|brew|pip|npm|script)s?\b|"
                        r"~/|\.(txt|py|md|js|json|csv|pdf|zip)\b", re.I)
SHELL_START = ("mkdir", "touch", "printf", "echo", "cp", "ls", "find", "cat", "git", "brew", "pip", "pip3", "npm",
               "curl", "wget", "python3", "du", "df", "grep", "head", "tail", "wc", "open")


def rescue_command(text: str) -> str | None:
    """Mingbird/Forge 'plain-text tool-call rescue': find a shell command the model wrote instead of calling a tool."""
    m = re.search(r'\{\s*"name"\s*:\s*"run_command"\s*,\s*"arguments"\s*:\s*\{\s*"command"\s*:\s*"((?:[^"\\]|\\.)*)"', text)
    if m:
        return json.loads('"' + m.group(1) + '"')
    for block in re.findall(r"```(?:bash|sh|zsh|shell|console)?\s*\n(.*?)```", text, re.S):
        lines = [l.strip().lstrip("$ ").strip() for l in block.strip().splitlines() if l.strip() and not l.strip().startswith("#")]
        if 1 <= len(lines) <= 3 and all(l.split()[0] in SHELL_START for l in lines):
            return " && ".join(lines)
    return None


FAILED_RESULT = re.compile(r"\[RESULT: FAILED|\[CHECK FAILED|^Refused|^Could not|^Nothing to|^Not found|"
                           r"^Edit not applied|timed out", re.M)
CLAIMS_SUCCESS = re.compile(r"\b(done|created|made|saved|moved|renamed|deleted|trashed|installed|downloaded|cloned|"
                            r"copied|completed|finished|success(fully)?|all set|i've|i have)\b", re.I)
ADMITS_FAILURE = re.compile(r"\b(fail(ed|s)?|couldn'?t|could not|can'?t|cannot|unable|not able|error|blocked|"
                            r"didn'?t|did not|wasn'?t|not (been )?(created|done|possible)|declined|refused)\b", re.I)


def overwrite_targets(command: str) -> list[Path]:
    """Existing files in Desktop/Documents/Downloads that this command would overwrite (>, >>, tee, cp, sed -i)."""
    import shlex
    flat = shell_skeleton(command).replace("$HOME", H)
    paths = re.findall(r"(?<![0-9&<>])>>?[ \t]*([^\s;&|<>']+)", flat)
    paths += re.findall(r"\btee\s+(?:-a\s+)?([^\s;&|]+)", flat)
    for seg in re.split(r"&&|\|\||;|\|", flat):
        try:
            words = shlex.split(seg)
        except ValueError:
            continue
        if words and words[0] == "cp" and len(words) >= 3:
            args = [w for w in words[1:] if not w.startswith("-")]
            if len(args) >= 2:
                dst = Path(args[-1]).expanduser()
                dst = dst if dst.is_absolute() else Path.home() / dst
                paths += [str(dst / Path(src).name) if dst.is_dir() else str(dst) for src in args[:-1]]
        if words[:2] == ["sed", "-i"] and len(words) >= 3:
            paths.append(words[-1])
    found = []
    for p in paths:
        if p.startswith("/dev/"):
            continue
        r = _inside_write_folders(p)
        if r and r.is_file() and r.stat().st_size <= 50 * 1024**2 and r not in found:
            found.append(r)
    return found


def backup_files(files: list[Path]) -> str:
    """Copy each file into workspace/backups/<time>/... before it is overwritten (Mingbird: backup on every write)."""
    import shutil
    if not files:
        return ""
    stamp = BACKUPS / datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    saved = []
    for f in files:
        dest = stamp / f.relative_to(Path.home())
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(f, dest)
        saved.append(f"~/{f.relative_to(Path.home())}")
        print(f"{DIM}  💾 backed up {saved[-1]} before overwriting (/backups to see){RESET}")
    return "\n[Backed up before overwrite: " + ", ".join(saved) + f" → {stamp}]"


def list_backups() -> str:
    if not BACKUPS.exists():
        return "  (no backups yet — Mini backs up a file automatically before a command overwrites it)"
    rows = []
    for d in sorted(BACKUPS.iterdir(), reverse=True)[:10]:
        for f in sorted(p for p in d.rglob("*") if p.is_file()):
            rows.append(f"  {d.name}  ~/{f.relative_to(d)}")
    return ("\n".join(rows) + f"\n  {DIM}restore with: cp \"{BACKUPS}/<time>/<path>\" ~/<path>{RESET}") if rows else "  (no backups yet)"


def prune_backups(days: int = 30):
    import shutil
    cutoff = datetime.datetime.now() - datetime.timedelta(days=days)
    for d in BACKUPS.glob("*") if BACKUPS.exists() else []:
        try:
            if datetime.datetime.strptime(d.name, "%Y-%m-%d_%H-%M-%S") < cutoff:
                shutil.rmtree(d)
        except ValueError:
            pass


def verify_created(command: str) -> str:
    """Finish check: don't trust the exit code alone; confirm the folders/files the command should create exist."""
    flat = shell_skeleton(command).replace("$HOME", H)
    wanted = (re.findall(r"\bmkdir\s+(?:-p\s+)?([^\s;&|']+)", flat)
              + re.findall(r"(?<![0-9&<>])>>?[ \t]*([^\s;&|<>']+)", flat))
    ok, missing = [], []
    for w in wanted:
        if w.startswith("/dev/"):
            continue
        p = Path(w.strip("'\"")).expanduser()
        p = p if p.is_absolute() else Path.home() / p
        (ok if p.exists() else missing).append(f"~/{p.relative_to(Path.home())}" if Path.home() in p.parents else str(p))
    if missing:
        return f"\n[CHECK FAILED: {', '.join(missing)} does not exist after the command. The task did NOT succeed.]"
    return f"\n[Verified: {', '.join(ok)} exists.]" if ok else ""


def result_hint(command: str, code: int, stdout: str) -> str:
    """Forge-style: never let a failure or an empty result look like success to the model."""
    if code != 0:
        return (f"\n[RESULT: FAILED (exit code {code}). Do NOT tell the user it worked. Read the error above, then "
                "either fix the command and try once more, or explain plainly what went wrong.]")
    if not stdout.strip() and re.match(r"\s*(ls|find|grep|egrep|rg|mdfind|cat|head|tail)\b", command):
        return ("\n[RESULT: nothing found / empty. Don't invent results. Try a different path or pattern once, or tell "
                "the user nothing matched.]")
    return ""


def call_tool(name: str, args: dict) -> str:
    try:
        if name == "system_info":
            print(f"{DIM}  💻 checking this Mac{RESET}")
            return system_info()
        if name in ("web_search", "read_webpage"):
            STATE["web_used"] = True
        if name == "web_search":
            print(f"{DIM}  🔎 searching: {args.get('query','')}{RESET}")
            return web_search(args.get("query", ""))
        if name == "read_webpage":
            print(f"{DIM}  📄 reading: {args.get('url','')}{RESET}")
            return read_webpage(args.get("url", ""))
        if name == "run_command":
            return run_command(args.get("command", ""))
        if name == "move_to_trash":
            return move_to_trash(args.get("path", ""))
        if name == "move_file":
            return move_file(args.get("source", ""), args.get("destination", ""))
        if name == "find_files":
            print(f"{DIM}  🔍 finding: {args.get('query', '')}{RESET}")
            return find_files(args.get("query", ""), args.get("folder", ""))
        if name == "read_file":
            print(f"{DIM}  📖 reading: {args.get('path', '')}{RESET}")
            return read_file(args.get("path", ""), int(args.get("start_line") or 1))
        if name == "write_file":
            return write_file(args.get("path", ""), args.get("content", ""))
        if name == "edit_file":
            return edit_file(args.get("path", ""), args.get("old_text", ""), args.get("new_text", ""))
        if name == "open_file":
            return open_file(args.get("path", ""))
        if name == "clipboard":
            return clipboard(args.get("action", ""), args.get("text", ""))
        if name == "remember":
            if STATE.get("web_used"):
                return ("Not saved: memories can't be created from web content. If this is really a fact about the "
                        "user, ask them to confirm it with /remember.")
            res = save_memory(args.get("fact", ""), source="model")
            print(f"{DIM}  🧠 {res}{RESET}")
            return res
    except Exception as e:  # a broken tool must never crash the chat
        return f"Tool error: {e}"
    return f"Unknown tool '{name}'. Available: " + ", ".join(t["function"]["name"] for t in TOOLS) + "."


def parse_calls(text: str) -> list[tuple[str, dict]]:
    calls = []
    for name, body in re.findall(r'<function name="([^"]+)">(.*?)</function>', text, re.S):
        args = {}
        for pname, val in re.findall(r'<param name="([^"]+)">(.*?)</param>', body, re.S):
            m = re.fullmatch(r"\s*<!\[CDATA\[(.*)\]\]>\s*", val, re.S)
            args[pname] = (m.group(1) if m else val).strip()
        calls.append((name, args))
    return calls


# ----------------------------------------------------------------------------- model

def build_prompt(history: list[dict], think: bool, core: list[str] = ()) -> str:
    # The system part never changes during a chat, so Ollama can reuse its cache of everything already
    # read and only process the newest message (seconds instead of re-reading the whole chat every turn).
    name = next((m.group(1) for f in core for m in [re.search(r"(?:name is|named|name:)\s*([A-Z][\w'-]+)", f, re.I)] if m), None)
    persona = PERSONA.replace("{name}", name.capitalize() if name else "there")
    system = persona + f"\n\nToday is {datetime.date.today():%A, %d %B %Y}."
    if core:  # loaded once per session, so it stays identical (and cached) for the whole chat
        system += ("\n\n# About the USER, the human you are talking to. These facts describe THEM, never you "
                   "(you are always Mini). Statements like \"I ...\" below are the user speaking about themselves.\n"
                   + "\n".join(f"- {m}" for m in core))
    p = "<s><|im_start|>system\n" + system + "\n\n" + TOOL_BLOCK + "<|im_end|>\n"
    for m in history:
        if m["role"] == "user":
            p += f"<|im_start|>user\n{m['content']}<|im_end|>\n"
        elif m["role"] == "tool":
            p += f"<|im_start|>user\n<tool_response>\n{m['content']}\n</tool_response><|im_end|>\n"
        else:  # assistant: keep only the final text, not old reasoning
            p += f"<|im_start|>assistant\n<think>\n\n</think>\n\n{m['content']}<|im_end|>\n"
    return p + "<|im_start|>assistant\n" + ("<think>\n" if think else "<think>\n\n</think>\n\n")


def stream(prompt: str, think: bool) -> str:
    """Stream the reply: reasoning in grey, answer in normal text, tool-call XML hidden."""
    # 0.7 = MiniCPM5's recommended no-think setting; less random than 1.0, which made the 2B model ramble/invent.
    opts = {"temperature": 0.9 if think else 0.7, "top_p": 0.95, "min_p": 0.0, "repeat_penalty": 1.05,
            "num_ctx": NUM_CTX, "num_predict": 4096 if think else 2048, "stop": ["<|im_end|>", "<|im_start|>"]}
    full, shown, in_think = "", 0, think
    if think:
        print(f"{DIM}  (thinking) ", end="", flush=True)
    with httpx.stream("POST", OLLAMA, json={"model": MODEL, "prompt": prompt, "raw": True, "stream": True, "options": opts, "keep_alive": KEEP_ALIVE},
                      timeout=600) as r:
        for line in r.iter_lines():
            if not line:
                continue
            chunk = json.loads(line)
            full += chunk.get("response", "")
            if chunk.get("done") and chunk.get("prompt_eval_count"):
                STATE["cpt"] = len(prompt) / chunk["prompt_eval_count"]     # exact chars-per-token for this model
            if in_think and "</think>" in full:
                print(full[shown:full.index("</think>")] + RESET + "\n", end="", flush=True)
                shown, in_think = full.index("</think>") + len("</think>"), False
                continue
            cut = full.find("<function")
            safe = len(full) - 9 if cut == -1 else cut      # hold back a few chars that might start "<function"
            if safe > shown:
                piece = full[shown:safe].lstrip("\n") if shown == 0 or full[shown - 1] == ">" else full[shown:safe]
                print(piece, end="", flush=True)
                if STATE.get("speaker"):
                    STATE["speaker"].feed(piece)
                shown = safe
    if "<function" not in full and shown < len(full):
        print(full[shown:], end="")
        if STATE.get("speaker"):
            STATE["speaker"].feed(full[shown:])
    if STATE.get("speaker"):
        STATE["speaker"].flush()        # speak the last sentence now, not after the status line
    if in_think:
        print(RESET, end="")
    print()
    if think and "</think>" not in full:
        msg = "(I ran out of thinking space before answering. Try /think off, or ask a smaller question.)"
        print(msg)
        return msg
    return full.split("</think>")[-1].strip()


def context_usage(history: list[dict], core: list[str]) -> dict:
    """What the NEXT message will carry, in tokens: measured after cleanup and without old thinking. Calibrated
    with Ollama's exact token count of the last prompt (about 3.4 characters per token for this model)."""
    cpt = STATE.get("cpt", 3.4)
    fixed = len(build_prompt([], False, core))
    hist = sum(len(m["content"]) + 30 for m in history)            # +30 ≈ the chat-format tags around each message
    tok = lambda chars: int(chars / cpt)
    return {"fixed": tok(fixed), "history": tok(hist), "total": tok(fixed + hist),
            "trim_at": tok(fixed + HISTORY_CHARS), "limit": NUM_CTX, "messages": len(history)}


def print_status(history: list[dict], core: list[str], shortened: int = 0):
    """One dim line after each reply: real context size now, and where trimming starts."""
    u = context_usage(history, core)
    pct, trim_pct = u["total"] * 100 // u["limit"], u["trim_at"] * 100 // u["limit"]
    bar = "".join("▓" if k * 10 < pct else ("┊" if k * 10 <= trim_pct < (k + 1) * 10 else "░") for k in range(10))
    extra = f" · shortened {shortened} tool output{'s' if shortened > 1 else ''}" if shortened else ""
    warn = " · older messages get trimmed soon" if u["total"] > u["trim_at"] * 0.85 else ""
    print(f"{DIM}  context {bar} {u['total'] / 1000:.1f}k / {u['limit'] // 1000}k ({pct}%) · trims at ~{trim_pct}%{extra}{warn}{RESET}")


def context_report(history: list[dict], core: list[str]) -> str:
    u = context_usage(history, core)
    return (f"  Context window: {u['limit']:,} tokens (the model's working memory, 2.3 GB RAM)\n"
            f"  • fixed (persona + tools + memories): {u['fixed']:,} tokens\n"
            f"  • conversation: {u['history']:,} tokens in {u['messages']} messages\n"
            f"  • total now: {u['total']:,} tokens ({u['total'] * 100 // u['limit']}%)\n"
            f"  • oldest messages are trimmed above ~{u['trim_at']:,} tokens ({u['trim_at'] * 100 // u['limit']}%); "
            f"the rest is room for replies\n"
            f"  {DIM}/delete clears the conversation · saved memories are never trimmed{RESET}")


def warm_up(core: list[str]):
    """Load the model and pre-read the fixed instructions in the background, so the first reply starts fast."""
    import threading
    def go():
        try:
            httpx.post(OLLAMA, timeout=120, json={"model": MODEL, "prompt": build_prompt([], False, core), "raw": True,
                       "stream": False, "keep_alive": KEEP_ALIVE, "options": {"num_ctx": NUM_CTX, "num_predict": 1}})
        except Exception:
            pass
    threading.Thread(target=go, daemon=True).start()


def unload_model():
    """Drop the model from RAM, which also throws away its cached copy of the conversation."""
    try:
        httpx.post(OLLAMA, json={"model": MODEL, "keep_alive": 0}, timeout=10)
    except Exception:
        pass


def trim(history: list[dict]) -> list[dict]:
    """When history outgrows its budget, drop the oldest turns in one big chunk (down to 60%), not one
    message per turn: every cut forces a full re-read, so cutting rarely keeps the cache fast."""
    size = lambda: sum(len(m["content"]) for m in history)
    if size() > HISTORY_CHARS:
        before = len(history)
        while size() > HISTORY_CHARS * 0.6 and len(history) > 2:
            history.pop(0)
        while history and history[0]["role"] != "user":
            history.pop(0)
        print(f"\n{DIM}  ✂️  context nearly full: trimmed {before - len(history)} older messages "
              f"(saved memories are not affected){RESET}")
    return history


def compact_tools(history: list[dict], turn_start: int):
    """After a turn, shrink its tool outputs (web pages, command output) to a short excerpt.
    The model already used the full text; keeping all of it would crowd out the conversation."""
    n = 0
    for m in history[turn_start:]:
        if m["role"] == "tool" and len(m["content"]) > TOOL_KEEP_CHARS:
            m["content"] = m["content"][:TOOL_KEEP_CHARS] + "\n...[shortened]"
            n += 1
    return n


# ----------------------------------------------------------------------------- chat loop

NOT_NAMES = {"tired", "fine", "good", "ok", "okay", "back", "here", "done", "ready", "sorry", "bored", "sick", "busy",
             "new", "lost", "confused", "happy", "sad", "hungry", "not", "a", "an", "the", "just", "going", "so", "very",
             "using", "working", "trying", "learning", "from", "in", "at", "on", "great", "well", "alright",
             "stuck", "home", "out", "free", "late", "sure", "glad", "excited", "fine.", "also", "still", "really"}


def detect_name(text: str) -> str | None:
    """'im alex', 'I am Alex', 'my name is Alex', 'call me Alex' -> 'Alex'."""
    t = text.strip().rstrip(".!")
    m = re.fullmatch(r"(?:(?:hi|hey|hello)[,!]?\s+)?(?:my name is|call me)\s+([A-Za-z][A-Za-z'-]{1,24})", t, re.I)
    if not m:
        m = re.fullmatch(r"(?:(?:hi|hey|hello)[,!]?\s+)?(?:i'?m|i am|this is)\s+([A-Za-z][A-Za-z'-]{1,24})", t, re.I)
        if m and m.group(1).lower() in NOT_NAMES:
            return None
    return m.group(1).capitalize() if m else None


COMMANDS = [   # (command, argument hint, what it does) — the single source for /help, the menu and Tab completion
    ("/help", "", "show this menu (or just type /)"),
    ("/talk", "", "voice mode: speak, and Mini answers out loud (local and private)"),
    ("/think", "[on|off]", "thinking mode: slower, better for math, logic, tricky code"),
    ("/context", "", "how full the model's working memory is, and what's in it"),
    ("/memories", "", "list everything Mini remembers about you"),
    ("/remember", "<fact>", "save a fact yourself"),
    ("/forget", "<n>", "delete one memory by its number"),
    ("/sessions", "", "list saved chats"),
    ("/resume", "[n]", "continue a saved chat (start with: mini --resume)"),
    ("/clear", "", "start a fresh conversation (memories kept)"),
    ("/delete", "[all]", "delete this conversation · 'all' = also memories, sessions, log (asks first)"),
    ("/backups", "", "files Mini backed up before changing them (kept 30 days)"),
    ("/permissions", "", "what Mini is and isn't allowed to do"),
    ("/exit", "", "quit (or Ctrl-D)"),
]
ALIASES = {"/voice": "/talk", "/speak": "/talk", "/quit": "/exit", "/bye": "/exit", "/q": "/exit", "/memory": "/memories", "/mem": "/memories",
           "/session": "/sessions", "/history": "/sessions", "/backup": "/backups", "/perms": "/permissions",
           "/permission": "/permissions", "/reset": "/delete", "/wipe": "/delete", "/ctx": "/context", "/?": "/help"}


def command_menu(prefix: str = "/") -> str:
    rows = [c for c in COMMANDS if c[0].startswith(prefix)] or COMMANDS
    w = max(len(c[0] + (" " + c[1] if c[1] else "")) for c in rows)
    return "\n".join(f"  {BOLD}{c[0]}{RESET}{DIM}{(' ' + c[1]) if c[1] else ''}{RESET}"
                     f"{' ' * (w - len(c[0] + (' ' + c[1] if c[1] else '')))}  {c[2]}" for c in rows) + \
        f"\n  {DIM}Tab completes commands · ↑/↓ recalls earlier messages{RESET}"


def resolve_command(word: str) -> tuple[str | None, str]:
    """'/res' -> ('/resume', '') if unique; unknown -> (None, suggestion text)."""
    import difflib
    word = ALIASES.get(word, word)
    names = [c[0] for c in COMMANDS]
    if word in names:
        return word, ""
    starts = [n for n in names if n.startswith(word)]
    if len(starts) == 1:
        return starts[0], ""
    if len(starts) > 1:
        return None, command_menu(word)
    near = difflib.get_close_matches(word, names + list(ALIASES), n=3, cutoff=0.6)
    near = list(dict.fromkeys(ALIASES.get(n, n) for n in near))
    return None, (f"  unknown command {word}" + (f" — did you mean {' or '.join(near)}?" if near else "")
                  + f"\n  {DIM}type / to see all commands{RESET}")


HISTORY_FILE = DATA / ".input_history"


PT = {"session": None}
SLASH_ARGS = {"/think": ["on", "off"], "/delete": ["all"]}


def setup_line_editing():
    """In a terminal: a live command popup as soon as you type / (prompt_toolkit), filtered as you type, ↑/↓ to pick,
    with ↑ history saved between runs. Scripts/tests (no terminal) fall back to plain input with Tab completion."""
    if sys.stdin.isatty() and sys.stdout.isatty():
        try:
            from prompt_toolkit import PromptSession
            from prompt_toolkit.completion import Completer, Completion
            from prompt_toolkit.history import FileHistory
            from prompt_toolkit.styles import Style

            class SlashCompleter(Completer):
                def get_completions(self, document, complete_event):
                    text = document.text_before_cursor
                    if not text.startswith("/"):
                        return
                    head, space, tail = text.partition(" ")
                    if not space:
                        for name, arg, desc in COMMANDS:
                            if name.startswith(head.lower()):
                                yield Completion(name, start_position=-len(head),
                                                 display=name + (f" {arg}" if arg else ""), display_meta=desc)
                    else:
                        for opt in SLASH_ARGS.get(resolve_command(head.lower())[0] or "", []):
                            if opt.startswith(tail):
                                yield Completion(opt, start_position=-len(tail))

            style = Style.from_dict({
                "completion-menu.completion": "bg:#2a2a2a #d8d8d8",
                "completion-menu.completion.current": "bg:#4b4b4b #ffffff bold",
                "completion-menu.meta.completion": "bg:#2a2a2a #8a8a8a",
                "completion-menu.meta.completion.current": "bg:#4b4b4b #c8c8c8",
                "scrollbar.background": "bg:#2a2a2a", "scrollbar.button": "bg:#6a6a6a"})
            PT["session"] = PromptSession(history=FileHistory(str(HISTORY_FILE)), completer=SlashCompleter(),
                                          complete_while_typing=True, style=style, reserve_space_for_menu=10)
            return
        except Exception:
            PT["session"] = None
    try:
        import readline
    except ImportError:
        return
    def complete(text, state):
        line = readline.get_line_buffer()
        if not line.startswith("/"):
            return None
        head, _, tail = line.partition(" ")
        if not _:
            opts = [c[0] + " " for c in COMMANDS if c[0].startswith(head)]
        else:
            hint = {"/think": ["on", "off"], "/delete": ["all"]}.get(resolve_command(head)[0] or head, [])
            opts = [h for h in hint if h.startswith(tail)]
        return opts[state] if state < len(opts) else None
    readline.set_completer(complete)
    readline.set_completer_delims(" ")
    if "libedit" in (readline.__doc__ or ""):
        readline.parse_and_bind("bind ^I rl_complete")
    else:
        readline.parse_and_bind("tab: complete")
    readline.set_history_length(500)
    try:
        readline.read_history_file(HISTORY_FILE)
    except (FileNotFoundError, OSError):
        pass
    import atexit
    atexit.register(lambda: _save_history(readline))


def _save_history(readline):
    try:
        readline.write_history_file(HISTORY_FILE)
    except OSError:
        pass


def read_line() -> str:
    """The 'you ›' prompt: live / popup in a terminal, plain input otherwise."""
    if PT["session"]:
        from prompt_toolkit.formatted_text import ANSI
        return PT["session"].prompt(ANSI(f"{BOLD}you ›{RESET} ")).strip()
    return input(prompt_text(f"{BOLD}you ›{RESET} ")).strip()


def ask(prompt: str) -> str:
    """Approval prompts: read an answer but keep 'yes'/'no' out of the ↑ history."""
    try:
        answer = input(prompt)
    except EOFError:
        return ""
    try:
        import readline
        n = readline.get_current_history_length()
        if n and readline.get_history_item(n) == answer:
            readline.remove_history_item(n - 1)
    except Exception:
        pass
    return answer.strip().lower()


def prompt_text(text: str) -> str:
    """Wrap colour codes so line editing measures the prompt width correctly (no cursor glitches)."""
    return re.sub(r"(\033\[[0-9;]*m)", "\001\\1\002", text)


PERMISSIONS = f"""Mini's permissions (permanent; only editing mini.py can change them):
  ✅ No approval: system_info (RAM/disk/CPU/battery), web search, reading public pages, saving memories
  👀 Needs "y":   read-only commands (ls, cat, find, grep, df, du, git status/log, top -l 1...)
  ✏️  Needs "yes": create or change files in Desktop, Documents, Downloads (mkdir, cp, write a file, run a script)
  🔍 No approval: find_files; read_file inside Desktop/Documents/Downloads (other folders, or after web content: "y")
  ✏️  Needs "yes": write_file / edit_file — shows a diff first, backs up the old version (/backups)
  👀 Needs "y":   open_file (never opens apps or scripts) · clipboard read ("y") · clipboard write (no approval)
  🗑  Needs "yes": move_to_trash — Desktop/Documents/Downloads only, recoverable with Finder's "Put Back"
  📦 Needs "yes": move_file — move/rename within those folders, never overwrites
  🌐 Needs "yes": downloads & git pull/fetch/clone, ping (internet on for that one command only)
  📦 Needs "yes": brew/pip/npm install (internet + package folders for that one command, 5 min max)
  🔒 Enforced by macOS itself, even if you approve: no permanent deletes in your folders · no writing outside them ·
       no network for normal commands · can't control or kill other apps · can't read .ssh, Keychains, browser
       data, Mail, Messages, shell history
  ⛔ Always refused: rm / permanent delete, sudo, system settings, kill, passwords/keys, git reset --hard,
       uploads (git push, curl -d/-F/-T, ssh, scp, rsync)
  📝 Log: every action and your decision → {AUDIT_LOG}"""


def main():
    try:
        httpx.get("http://127.0.0.1:11434/api/tags", timeout=3)
    except Exception:
        sys.exit("Ollama isn't running. Start it first:\n  OLLAMA_FLASH_ATTENTION=1 OLLAMA_KV_CACHE_TYPE=q8_0 ollama serve")
    think, history = False, []
    listener = speaker = None
    session = new_session_path()
    setup_line_editing()
    if "--resume" in sys.argv and list_sessions():
        session, data = list_sessions()[0]
        history = data.get("history", [])
        print(f"{DIM}resumed: {data.get('title', '')} ({len(history)} messages){RESET}")
    core = core_memories()
    warm_up(core)
    prune_backups()
    cap_audit_log()
    print(f"{BOLD}Mini{RESET} (MiniCPM5-2B, local). Tools: web search, read pages, run commands (asks first), memory.")
    print(f"{DIM}Type / to see commands · ↑/↓ to pick or recall earlier messages{RESET}\n")
    while True:
        try:
            user = listener.listen() if listener else read_line()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not user:
            continue
        if listener and STOP_TALK.match(user):
            user = "/talk"
        # Slash commands are handled here and never sent to the model, even with typos or extra text.
        if user.startswith("/"):
            word, _, arg = user.partition(" ")
            word, arg = word.lower().rstrip("?!.") or "/", arg.strip()
            if word == "/":
                print(command_menu()); continue
            full, hint = resolve_command(word)
            if not full:
                print(hint); continue
            cmd = full[1:]
            if cmd in ("exit", "quit", "bye", "q"):
                if listener:
                    speaker.stop(); listener.close()
                break
            elif cmd == "think":
                think = (not think) if arg.lower() not in ("on", "off") else arg.lower() == "on"
                print(f"{DIM}thinking mode {'ON' if think else 'OFF'}{RESET}")
            elif cmd == "clear":
                history, core = [], core_memories(); print(f"{DIM}conversation cleared (memories kept){RESET}")
            elif cmd in ("memories", "memory", "mem"):
                print(list_memories())
            elif cmd in ("delete", "reset", "wipe"):
                if arg.lower() in ("all", "everything"):
                    n = db().execute("SELECT count(*) FROM memories").fetchone()[0]
                    print(f"{YEL}  This permanently deletes the conversation, all {n} memories, all saved sessions and the command log. "
                          f"It cannot be undone.{RESET}")
                    try:
                        sure = ask(prompt_text(f"{YEL}  Type 'delete all' to confirm: {RESET}")) == "delete all"
                    except EOFError:
                        sure = False
                    if sure:
                        con = db(); con.execute("DELETE FROM memories"); con.commit()
                        AUDIT_LOG.unlink(missing_ok=True)
                        import shutil
                        shutil.rmtree(SESSIONS, ignore_errors=True)
                        HISTORY_FILE.unlink(missing_ok=True)
                        if PT["session"]:
                            from prompt_toolkit.history import InMemoryHistory
                            PT["session"].history = InMemoryHistory()
                        try:
                            import readline; readline.clear_history()
                        except Exception:
                            pass
                        session = new_session_path()
                        history, core = [], []
                        unload_model()
                        print(f"{DIM}everything deleted: conversation, {n} memories, saved sessions, command log{RESET}")
                    else:
                        print(f"{DIM}cancelled — nothing deleted{RESET}")
                else:
                    session.unlink(missing_ok=True)
                    history, core, session = [], core_memories(), new_session_path()
                    unload_model()
                    print(f"{DIM}conversation context deleted (also cleared from the model's memory). "
                          f"Your saved memories are kept — /delete all removes those too.{RESET}")
            elif cmd == "talk":
                if listener:
                    speaker.stop(); listener.close()
                    listener = speaker = STATE["speaker"] = None
                    print(f"{DIM}  talk mode OFF — back to typing{RESET}")
                else:
                    listener, speaker = start_talk(known_name())
                    STATE["speaker"] = speaker
            elif cmd == "help":
                print(command_menu())
            elif cmd == "context":
                print(context_report(history, core))
            elif cmd in ("sessions", "session", "history"):
                print(show_sessions(session))
            elif cmd == "resume":
                rows = list_sessions()
                pick = int(arg) if arg.isdigit() else (2 if rows and rows[0][0] == session else 1)
                if 1 <= pick <= len(rows):
                    session, data = rows[pick - 1]
                    history, core = data.get("history", []), core_memories()
                    print(f"{DIM}resumed: {data.get('title', '')} ({len(history)} messages). Continue where you left off.{RESET}")
                    for m in [m for m in history if m["role"] in ("user", "assistant")][-4:]:
                        who = "you" if m["role"] == "user" else "mini"
                        body = re.sub(r"^\[Memory —[^\]]*\]\n", "", m["content"]).split("\n(This was saved")[0]
                        print(f"{DIM}  {who} › {body[:140].replace(chr(10), ' ')}{'…' if len(body) > 140 else ''}{RESET}")
                else:
                    print(f"{DIM}no session #{arg or pick} — see /sessions{RESET}")
            elif cmd in ("backups", "backup"):
                print(list_backups())
            elif cmd in ("permissions", "perms", "permission"):
                print(PERMISSIONS)
            elif cmd == "remember" and arg:
                print(f"{DIM}{save_memory(arg)}{RESET}")
            elif cmd == "forget" and arg.lstrip("#").isdigit():
                print(f"{DIM}{forget_memory(int(arg.lstrip('#')))}{RESET}")
                core = core_memories()   # take effect now, not after a restart
            elif cmd in ("remember", "forget"):
                print(f"{DIM}usage: /remember <fact>   ·   /forget <number> (see /memories){RESET}")
            else:
                print(command_menu())
            continue

        # Names are saved by code: small models rarely call `remember` for a quick "I'm X".
        name = detect_name(user)
        if name:
            print(f"{DIM}  🧠 {save_memory(f"The user's name is {name}")}{RESET}")

        # Structure over prompting: small models often say "got it" without calling the tool,
        # so an explicit "remember ..." request is saved by code, not left to the model.
        m = re.search(r"\bremember(?:\s+that)?\s*[:,]?\s+(.+)", user, re.I)
        if m and not user.rstrip().endswith("?"):
            fact = m.group(1).strip().rstrip(".!")
            if fact.lower() in ("that", "this", "it", "that please", "this please", "it please"):
                # "I'm learning Rust. Remember that" -> the fact is what came before "remember".
                fact = re.split(r"[.,;!]?\s*(?:please\s+)?remember\b", user, flags=re.I)[0].strip().rstrip(".,!")
            if len(fact) < 4:
                fact = ""
            if fact:
                print(f"{DIM}  🧠 {save_memory(fact)}{RESET}")
                user += "\n(This was saved to your long-term memory already; do not call remember for it.)"
        # Relevant memories ride along with this message (not in the system prompt), so the cached
        # start of the conversation never changes.
        STATE["question"], STATE["web_used"] = user, False
        memories = [m for m in recall(user) if m not in core]
        if memories:
            user = ("[Memory — facts about the USER (the human typing this, never you, Mini): "
                    + "; ".join(memories) + "]\n" + user)
        turn_start, searched, raw = len(history), False, STATE["question"]
        seen: dict = {}    # tool-call signatures this turn, for the repetition breaker
        failures, gated, rescued = [], False, False   # finish gate + text-command rescue state for this turn
        history.append({"role": "user", "content": user})
        print(f"{BOLD}mini ›{RESET} ", end="", flush=True)
        try:
            for step in range(MAX_TOOL_STEPS + 1):
                reply = stream(build_prompt(trim(history), think, core), think)
                calls = parse_calls(reply)
                text = re.sub(r"<function.*", "", reply, flags=re.S).strip()
                # Code decides, not the 2B model: if it sounds unsure about a question and didn't search, search
                # for it automatically and answer again from the evidence (small models often skip the tool).
                if (step == 0 and not calls and not searched and UNSURE.search(text)
                        and re.search(r"\?|^(what|who|when|where|which|how|why|tell me|explain|define)\b", raw, re.I)):
                    print(f"{DIM}  (not sure — checking the web){RESET}")
                    searched = True
                    query = re.sub(r"^(what|who)\s+(is|are|was|were)\s+|[?!.]+$", "", raw.strip(), flags=re.I) or raw
                    history.append({"role": "assistant", "content":
                                    f'<function name="web_search"><param name="query">{query}</param></function>'})
                    history.append({"role": "tool", "content": call_tool("web_search", {"query": query})})
                    print(f"{BOLD}mini ›{RESET} ", end="", flush=True)
                    continue
                if any(n == "web_search" for n, _ in calls):
                    searched = True
                rescued_cmd = rescue_command(text) if (not calls and not seen and not rescued
                                                        and ACTION_REQUEST.search(raw) and MAC_TARGET.search(raw)) else None
                if rescued_cmd:
                    rescued = True
                    print(f"{DIM}  ↪ Mini wrote the command instead of running it — running it the normal way "
                          f"(you still approve){RESET}")
                    history.append({"role": "assistant", "content": f'<function name="run_command"><param name="command">'
                                    f'<![CDATA[{rescued_cmd}]]></param></function>'})
                    result = guarded_call("run_command", {"command": rescued_cmd}, seen)
                    history.append({"role": "tool", "content": result})
                    if FAILED_RESULT.search(result):
                        failures.append(f"run_command {rescued_cmd}"[:120])
                    print(f"{BOLD}mini ›{RESET} ", end="", flush=True)
                    continue
                if not calls and failures and not gated and CLAIMS_SUCCESS.search(text) and not ADMITS_FAILURE.search(text):
                    gated = True    # Mingbird-style finish gate: the code checks, not the model
                    if speaker:
                        speaker.stop(); speaker.reset()     # don't keep reading out a wrong "Done!"
                    print(f"{YEL}  ↺ correction: that didn't actually succeed ({failures[-1]}){RESET}")
                    history.append({"role": "assistant", "content": text})
                    history.append({"role": "user", "content": f"[Harness check: this did NOT succeed: {failures[-1]}. "
                                    "Your reply claimed success. Answer again in 1-3 sentences: say plainly what "
                                    "happened and what can be done instead.]"})
                    print(f"{BOLD}mini ›{RESET} ", end="", flush=True)
                    continue
                if not calls or step == MAX_TOOL_STEPS:
                    if calls:   # out of steps while still calling tools: ask for a plain answer instead of raw XML
                        history.append({"role": "user", "content": "[Step limit reached. Answer the user now in plain "
                                        "words with what you have; do not call any more tools.]"})
                        print(f"{BOLD}mini ›{RESET} ", end="", flush=True)
                        text = re.sub(r"<function.*", "", stream(build_prompt(trim(history), False, core), False),
                                      flags=re.S).strip() or "(I couldn't finish that in the allowed steps.)"
                    history.append({"role": "assistant", "content": text or "(no answer)"})
                    break
                # Keep the call in history (native format) so the model sees what it asked for.
                history.append({"role": "assistant", "content": reply})
                declined = False
                for name, args in calls:
                    result = guarded_call(name, args, seen)
                    history.append({"role": "tool", "content": result})
                    declined = declined or result.startswith(DECLINED_MSG[:30])
                    if name in ("run_command", "move_file", "move_to_trash", "write_file", "edit_file") and FAILED_RESULT.search(result):
                        failures.append(f"{name} {next(iter(args.values()), '')}"[:120])
                if declined:   # you said no: answer in code (accurate, and saves a model call)
                    msg = "OK, I won't do that. Anything else?"
                    print(f"{BOLD}mini ›{RESET} {msg}")
                    if speaker:
                        speaker.feed(msg)
                    history.append({"role": "assistant", "content": msg})
                    break
                print(f"{BOLD}mini ›{RESET} ", end="", flush=True)
            shortened = compact_tools(history, turn_start)
            print_status(history, core, shortened)
            save_session(session, history)
            if speaker:
                speaker.flush(); speaker.wait(); speaker.reset()
        except KeyboardInterrupt:
            print(f"\n{DIM}(stopped){RESET}")
            if speaker:
                speaker.stop(); speaker.reset()
        except httpx.HTTPError as e:
            print(f"\n{YEL}Ollama error: {e}. Is Ollama running? (type mini in a new Terminal to start it){RESET}")
        except Exception as e:   # a bug in a tool or parser must never kill the whole chat
            print(f"\n{YEL}Something went wrong ({type(e).__name__}: {e}). The chat is still running.{RESET}")
        if history and history[-1]["role"] != "assistant":
            history.append({"role": "assistant", "content": "(no answer — stopped)"})
        print()


if __name__ == "__main__":
    main()
