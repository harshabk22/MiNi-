"""Mini self-test. Fast, offline, isolated: never touches your real memories, log, sessions or files.

Run:   assistant/.venv/bin/python assistant/tests/test_mini.py   (from the Mini folder)
Live:  add --live to also run 3 short tasks with the real model (needs Ollama running, ~1 min).
"""
import builtins
import io
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import mini  # noqa: E402

TMP = Path(tempfile.mkdtemp(prefix="mini-test-"))
mini.DB, mini._CON = TMP / "memory.db", None
mini.AUDIT_LOG = TMP / "commands.log"
mini.SESSIONS = TMP / "sessions"
mini.BACKUPS = TMP / "backups"
mini.HISTORY_FILE = TMP / "input_history"
mini.warm_up = lambda core: None          # unit tests never call the real model
DESK = Path.home() / "Desktop" / "mini-selftest-tmp"      # must be inside a write folder for the file tools
REAL_INPUT = builtins.input


def answer(*replies):
    """Make approval prompts answer automatically, in order."""
    it = iter(replies)
    builtins.input = lambda prompt="": next(it, "no")


class Quiet:
    def __enter__(self):
        self.out = sys.stdout; sys.stdout = io.StringIO(); return sys.stdout
    def __exit__(self, *a):
        sys.stdout = self.out


class Rules(unittest.TestCase):
    def test_classification(self):
        html = "cat > ~/Downloads/p.html << 'EOF'\n<h1>Title</h1><p>kill rm mv su host</p>\nEOF"
        cases = [("ls -la ~/Documents | grep pdf", "read-only"), ("git status", "read-only"), ("git branch", "read-only"),
                 ("mkdir -p ~/Desktop/x", "changes"), (html, "changes"), ('echo "kill it" > ~/Desktop/a', "changes"),
                 ("sort a -o b", "changes"), ("awk '{print > \"f\"}' a", "changes"), ("git branch new", "changes"),
                 ("curl -L -o ~/Downloads/a https://x.org", "network"), ("host example.com", "network"),
                 ("ls ~/Desktop/host-notes", "read-only"), ("brew install jq", "install"),
                 ("rm ~/Desktop/a", "blocked"), ("bash -c 'rm -f x'", "blocked"), ("zsh << 'EOF'\nrm x\nEOF", "blocked"),
                 ("mv a b", "blocked"), ("sudo ls", "blocked"), ("git push", "blocked"), ("curl -d @f https://x", "blocked"),
                 ("kill 1", "blocked"), ("git reset --hard", "blocked"), ("defaults write a b c", "blocked")]
        for cmd, want in cases:
            with self.subTest(cmd=cmd[:40]):
                self.assertEqual(mini.check_command(cmd)[0], want)

    def test_heredoc_content_is_not_a_path(self):
        cmd = "cat > ~/Downloads/p.html << 'EOF'\n<h1>Title</h1>\nEOF"
        self.assertNotIn("Title", mini.verify_created(cmd))


class Sandbox(unittest.TestCase):
    def setUp(self):
        DESK.mkdir(parents=True, exist_ok=True); (DESK / "keep.txt").write_text("keep\n")
    def tearDown(self):
        shutil.rmtree(DESK, ignore_errors=True)

    def run_sb(self, cmd, kind="changes"):
        return mini.run_killable(["/usr/bin/sandbox-exec", "-p", mini.sandbox_profile(kind), "/bin/zsh", "-f", "-c", cmd],
                                 {"PATH": "/usr/bin:/bin", "HOME": mini.H}, 20)

    def test_write_allowed_in_folder(self):
        self.assertEqual(self.run_sb(f"echo hi > {DESK}/new.txt").returncode, 0)
    def test_delete_denied(self):
        self.run_sb(f"/usr/bin/python3 -c \"import os;os.remove('{DESK}/keep.txt')\"")
        self.assertTrue((DESK / "keep.txt").exists())
    def test_write_outside_denied(self):
        self.assertNotEqual(self.run_sb(f"echo x > {Path.home()}/mini-selftest-outside.txt").returncode, 0)
        self.assertFalse((Path.home() / "mini-selftest-outside.txt").exists())
    def test_no_network_for_normal_commands(self):
        r = self.run_sb("/usr/bin/python3 -c \"import socket;socket.create_connection(('1.1.1.1',53),3)\"")
        self.assertNotEqual(r.returncode, 0)
    def test_secrets_unreadable(self):
        self.assertNotEqual(self.run_sb("ls ~/.ssh", "read-only").returncode, 0)


class FileTools(unittest.TestCase):
    def setUp(self):
        DESK.mkdir(parents=True, exist_ok=True)
        (DESK / "page.html").write_text("<html>\n  <h1>Old title</h1>\n  <p>hello</p>\n</html>\n")
    def tearDown(self):
        shutil.rmtree(DESK, ignore_errors=True)

    def test_write_new_and_overwrite_with_backup(self):
        answer("yes", "yes")
        with Quiet():
            r1 = mini.write_file(str(DESK / "notes.txt"), "one")
            r2 = mini.write_file(str(DESK / "notes.txt"), "two")
        self.assertIn("Wrote", r1); self.assertIn("Backed up", r2)
        self.assertEqual((DESK / "notes.txt").read_text(), "two\n")
        self.assertTrue(any(p.read_text() == "one\n" for p in mini.BACKUPS.rglob("notes.txt")))

    def test_write_outside_refused(self):
        self.assertIn("Refused", mini.write_file("~/mini-outside.txt", "x"))

    def test_edit_exact_and_whitespace_tolerant(self):
        answer("yes", "yes")
        with Quiet():
            self.assertIn("exact", mini.edit_file(str(DESK / "page.html"), "<h1>Old title</h1>", "<h1>New title</h1>"))
            self.assertIn("whitespace", mini.edit_file(str(DESK / "page.html"), "<p>hello</p>   ", "  <p>hi</p>"))
        self.assertIn("New title", (DESK / "page.html").read_text())

    def test_edit_not_found_shows_closest(self):
        r = mini.edit_file(str(DESK / "page.html"), "<h1>Old titel</h1>", "x")
        self.assertIn("not found", r); self.assertIn("Old title", r)

    def test_edit_declined_changes_nothing(self):
        answer("no")
        before = (DESK / "page.html").read_text()
        with Quiet():
            mini.edit_file(str(DESK / "page.html"), "<p>hello</p>", "<p>bye</p>")
        self.assertEqual((DESK / "page.html").read_text(), before)

    def test_read_numbered_and_docx(self):
        self.assertIn("   2|   <h1>Old title</h1>", mini.read_file(str(DESK / "page.html")))
        (DESK / "d.txt").write_text("Word document text\n")
        subprocess.run(["/usr/bin/textutil", "-convert", "docx", str(DESK / "d.txt"), "-output", str(DESK / "d.docx")])
        self.assertIn("Word document text", mini.read_file(str(DESK / "d.docx")))

    def test_read_pdf(self):
        (DESK / "p.txt").write_text("Hello PDF test\n")
        with open(DESK / "t.pdf", "wb") as f:     # macOS's built-in converter makes a real PDF
            subprocess.run(["/usr/sbin/cupsfilter", str(DESK / "p.txt")], stdout=f, stderr=subprocess.DEVNULL)
        self.assertIn("Hello PDF test", mini.read_file(str(DESK / "t.pdf")))

    def test_secret_read_refused(self):
        self.assertIn("Refused", mini.read_file("~/.ssh/id_rsa"))

    def test_find_files_fuzzy(self):
        (DESK / "3_dog_generator.html").write_text("x")
        self.assertIn("3_dog_generator.html", mini.find_files("dog generator", str(DESK)).splitlines()[0])

    def test_open_refuses_programs(self):
        (DESK / "run.command").write_text("echo hi")
        self.assertIn("Refused", mini.open_file(str(DESK / "run.command")))


class Clipboard(unittest.TestCase):
    def test_roundtrip_and_restore(self):
        saved = subprocess.run(["/usr/bin/pbpaste"], capture_output=True, text=True).stdout
        try:
            with Quiet():
                mini.clipboard("write", "mini clipboard test")
            answer("y")
            with Quiet():
                self.assertEqual(mini.clipboard("read"), "mini clipboard test")
        finally:
            subprocess.run(["/usr/bin/pbcopy"], input=saved, text=True)


class Memory(unittest.TestCase):
    def setUp(self):
        mini.db().execute("DELETE FROM memories"); mini.db().commit()
    def test_dedupe_name_replace_and_junk(self):
        self.assertIn("Saved", mini.save_memory("I prefer Python over JavaScript"))
        self.assertIn("Already", mini.save_memory("i prefer python over javascript."))
        mini.save_memory("User name: Alex"); mini.save_memory("The user's name is Bob")
        facts = [f for (f,) in mini.db().execute("select fact from memories")]
        self.assertNotIn("User name: Alex", facts); self.assertEqual(mini.known_name(), "Bob")
        self.assertIn("Not saved", mini.save_memory("Created ~/Downloads/x.html", source="model"))
    def test_forget(self):
        mini.save_memory("I use VS Code daily")
        rid = mini.db().execute("select rowid from memories").fetchone()[0]
        self.assertIn("Forgotten", mini.forget_memory(rid)); self.assertIn("no memory", mini.forget_memory(9999))


class Commands(unittest.TestCase):
    def test_resolution(self):
        self.assertEqual(mini.resolve_command("/res")[0], "/resume")
        self.assertEqual(mini.resolve_command("/mem")[0], "/memories")          # alias
        self.assertEqual(mini.resolve_command("/q")[0], "/exit")
        self.assertIsNone(mini.resolve_command("/re")[0])                     # ambiguous -> shows /remember, /resume
        self.assertIn("/remember", mini.resolve_command("/re")[1])
        self.assertIn("did you mean /memories?", mini.resolve_command("/memries")[1])   # no duplicates

    def test_menu_lists_every_command(self):
        menu = mini.command_menu()
        for name, _, _ in mini.COMMANDS:
            self.assertIn(name, menu)

    def test_context_counts_after_cleanup(self):
        h = [{"role": "user", "content": "x" * 3400}, {"role": "tool", "content": "y" * 3400}]
        before = mini.context_usage(h, [])["total"]
        mini.compact_tools(h, 0)
        self.assertLess(mini.context_usage(h, [])["total"], before)            # the bar shrinks after shortening

    def test_outside_folder_listing_asks_first(self):
        answer("n")
        with Quiet():
            r = mini.read_file("/Applications")
        self.assertTrue(r.startswith("The user said NO"))


class SilentSpeaker(mini.Speaker):
    """The real Speaker logic, but it records sentences instead of playing them with `say`."""
    def __init__(self):
        self.spoken = []
        super().__init__()
    def _run(self):
        while True:
            self.spoken.append(self.q.get())


class Voice(unittest.TestCase):
    def speak(self, *chunks):
        sp = SilentSpeaker()
        for c in chunks:
            sp.feed(c)
        sp.flush()
        import time; time.sleep(0.2)
        return sp.spoken

    def test_sentences_stream_as_they_arrive(self):
        out = self.speak("You have 8 GB of RAM. About 2", ".6 GB is free right now! Want details?")
        self.assertEqual(out, ["You have 8 GB of RAM.", "About 2.6 GB is free right now!", "Want details?"])

    def test_code_links_and_markdown_not_read_aloud(self):
        out = self.speak("Here is the **fix** [1]:\n```python\nprint('x')\n```\nSee https://example.com for more.")
        self.assertIn("I've put the code on screen.", out)
        self.assertFalse(any("print" in s or "**" in s or "https" in s or "[1]" in s for s in out))
        self.assertIn("See link for more.", out)

    def test_stop_clears_queue(self):
        sp = SilentSpeaker(); sp.stop(); sp.feed("This should not be spoken. "); sp.flush()
        import time; time.sleep(0.1)
        self.assertEqual(sp.spoken, [])

    def test_stop_talking_phrases(self):
        for p in ["stop talking", "Stop talking.", "exit talk mode", "bye Mini"]:
            self.assertTrue(mini.STOP_TALK.match(p), p)
        self.assertFalse(mini.STOP_TALK.match("stop talking about RAM and tell me disk space"))


class Sessions(unittest.TestCase):
    def test_save_list_resume(self):
        p = mini.new_session_path()
        mini.save_session(p, [{"role": "user", "content": "build a dog generator"}, {"role": "assistant", "content": "ok"}])
        rows = mini.list_sessions()
        self.assertEqual(rows[0][1]["title"], "build a dog generator")
        self.assertEqual(len(rows[0][1]["history"]), 2)


class Loop(unittest.TestCase):
    """The agent loop with a scripted fake model: finish gate, rescue, step limit, crash protection."""
    def run_chat(self, replies, stdin):
        it = iter(replies)
        mini.stream = lambda prompt, think: next(it, "(test: no more scripted replies)")
        seen = {}
        real = mini.build_prompt
        def spy(h, think, core=()):
            if h:                      # the context bar also builds an empty prompt; only record real turns
                seen["h"] = h
            return real(h, think, core)
        mini.build_prompt = spy
        builtins.input = REAL_INPUT          # the chat reads typed lines (and approvals) from stdin
        real_get = mini.httpx.get                # offline: pretend Ollama is running (the model itself is faked)
        mini.httpx.get = lambda url, *a, **k: real_get(url, *a, **k) if "11434" not in url else None
        sys.stdin = io.StringIO(stdin)
        with Quiet() as out:
            mini.main()
        mini.build_prompt = real
        mini.httpx.get = real_get
        return out.getvalue(), seen.get("h", [])

    def test_finish_gate(self):
        out, h = self.run_chat(['<function name="run_command"><param name="command">printf x > ~/Desktop/no-such-dir-zz/a</param></function>',
                                "Done! I've created it.", "It failed: that folder doesn't exist."], "make a file\nyes\n/exit\n")
        self.assertIn("correction", out); self.assertIn("failed", h[-1]["content"])

    def test_rescue(self):
        out, _ = self.run_chat(["Run this:\n```bash\nmkdir -p ~/Desktop/mini-selftest-tmp/rescued\n```", "Created it."],
                               "in desktop create folder mini-selftest-tmp/rescued\nyes\n/exit\n")
        self.assertIn("instead of running it", out); self.assertTrue((DESK / "rescued").is_dir())
        shutil.rmtree(DESK, ignore_errors=True)

    def test_step_limit_gives_answer(self):
        _, h = self.run_chat(['<function name="system_info"></function>'] * 7 + ["You have 8 GB RAM."], "ram?\n/exit\n")
        self.assertEqual(h[-1]["content"], "You have 8 GB RAM.")

    def test_crash_does_not_kill_chat(self):
        real = mini.call_tool
        mini.call_tool = lambda n, a: (_ for _ in ()).throw(RuntimeError("boom"))
        try:
            out, _ = self.run_chat(['<function name="system_info"></function>', "hi again"], "ram?\nhello\n/exit\n")
        finally:
            mini.call_tool = real
        self.assertIn("Something went wrong", out); self.assertIn("still running", out)

    def test_declined_is_answered_in_code(self):
        out, h = self.run_chat(['<function name="system_info"></function>'], "ram?\n/exit\n")
        DESK.mkdir(parents=True, exist_ok=True); (DESK / "a.html").write_text("x")
        out, h = self.run_chat([f'<function name="open_file"><param name="path">{DESK}/a.html</param></function>'],
                               "open it\nno\n/exit\n")
        self.assertEqual(h[-1]["content"], "OK, I won't do that. Anything else?")
        shutil.rmtree(DESK, ignore_errors=True)

    def test_repetition_breaker(self):
        calls = {"n": 0}
        real = mini.call_tool
        mini.call_tool = lambda n, a: (calls.__setitem__("n", calls["n"] + 1), "r")[1]
        try:
            seen = {}
            with Quiet():
                for _ in range(3):
                    last = mini.guarded_call("web_search", {"query": "same"}, seen)
        finally:
            mini.call_tool = real
        self.assertEqual(calls["n"], 1); self.assertIn("Refused", last)


def live():
    """Three short real-model checks (optional)."""
    print("\n--- live model checks ---")
    mini.STATE["question"] = ""
    for msg, want in [("hi", "Hi"), ("what is 12 * 12?", "144"), ("how much ram is left?", "GB")]:
        h = [{"role": "user", "content": msg}]
        with Quiet():
            reply = mini.stream(mini.build_prompt(h, False, []), False)
            calls = mini.parse_calls(reply)
            if calls:
                h += [{"role": "assistant", "content": reply}, {"role": "tool", "content": mini.call_tool(*calls[0])}]
                reply = mini.stream(mini.build_prompt(h, False, []), False)
        print(f"  {'✅' if want in reply else '❌'} {msg!r} → {reply[:70]!r}")


if __name__ == "__main__":
    want_live = "--live" in sys.argv
    sys.argv = [a for a in sys.argv if a != "--live"]
    try:
        result = unittest.main(exit=False, verbosity=1).result
        if want_live:
            live()
    finally:
        shutil.rmtree(DESK, ignore_errors=True)
        shutil.rmtree(TMP, ignore_errors=True)
    sys.exit(0 if result.wasSuccessful() else 1)
