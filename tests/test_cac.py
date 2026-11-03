#!/usr/bin/env python3
"""Tests for scripts/cac.py. Stdlib only and free: a fake `claude` speaks the stream-json protocol.

    python3 tests/test_cac.py
"""
import importlib.util
import json
import os
import pty
import re
import select
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import termios
import time
import unittest

sys.dont_write_bytecode = True
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "cac.py")
spec = importlib.util.spec_from_file_location("cac", SCRIPT)
cac = importlib.util.module_from_spec(spec)
sys.modules["cac"] = cac
spec.loader.exec_module(cac)

FAKE_CLAUDE = r'''#!/usr/bin/env python3
import json, os, select, sys, time
log = open(os.environ["CAC_TEST_LOG"], "a", buffering=1)
log.write(json.dumps({"argv": sys.argv[1:]}) + "\n")
if os.environ.get("CAC_TEST_REJECT") and "--thinking-display" in sys.argv:
    print("error: unknown option '--thinking-display'", file=sys.stderr, flush=True)
    sys.exit(1)
def out(o):
    sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
print("claude.ai connectors are disabled because of the key", file=sys.stderr, flush=True)
mode = "auto"; cost = 0.0; rid = 0
def delta(t):
    out({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": t}}})
def stop():
    out({"type": "stream_event", "event": {"type": "content_block_stop"}})
def result(error=False, subtype="success", text=None):
    global cost
    cost += 0.01
    out({"type": "result", "subtype": subtype, "is_error": error, "total_cost_usd": cost, "result": text,
         "usage": {"input_tokens": 1500, "output_tokens": 20}})
def read():
    line = sys.stdin.readline()
    return json.loads(line) if line else None
out({"type": "system", "subtype": "init", "session_id": "fake-session", "permissionMode": mode})
while True:
    m = read()
    if m is None:
        sys.exit(0)
    log.write(json.dumps(m) + "\n")
    if m["type"] == "control_request":
        r = m["request"]
        if r["subtype"] == "set_permission_mode":
            if r["mode"] in ("default", "acceptEdits", "plan", "auto", "dontAsk"):
                mode = r["mode"]
                out({"type": "control_response", "response": {"subtype": "success", "request_id": m["request_id"], "response": {"mode": mode}}})
                out({"type": "system", "subtype": "status", "permissionMode": mode, "session_id": "fake-session"})
            else:
                out({"type": "control_response", "response": {"subtype": "error", "request_id": m["request_id"], "error": "must be one of the modes"}})
        continue
    if m["type"] != "user":
        continue
    text = m["message"]["content"]
    if text.startswith("slow"):
        delta("streaming ")
        while True:
            if select.select([sys.stdin], [], [], 0.05)[0]:
                c = read()
                log.write(json.dumps(c) + "\n")
                if c and c.get("request", {}).get("subtype") == "interrupt":
                    out({"type": "control_response", "response": {"subtype": "success", "request_id": c["request_id"], "response": {}}})
                    stop()
                    result(error=True, subtype="error_during_execution")
                    break
            delta("x ")
    elif text.startswith("idlereq"):
        result()
        time.sleep(0.3)
        out({"type": "control_request", "request_id": "bg", "request": {"subtype": "can_use_tool", "tool_name": "Bash", "input": {"command": "bg job"}}})
        log.write(json.dumps({"answer": read()}) + "\n")
    elif text.startswith("late"):
        result()
        time.sleep(0.3)
        delta("late text")
        stop()
    elif text.startswith("promptresult"):
        out({"type": "control_request", "request_id": "pr", "request": {"subtype": "can_use_tool", "tool_name": "Bash", "input": {"command": "still asking"}}})
        result()
        log.write(json.dumps({"answer": read()}) + "\n")
    elif text.startswith("badjson"):
        sys.stdout.write("null\n[1]\n"); sys.stdout.flush()
        out({"type": "assistant", "message": {"content": "not a list"}})
        out({"type": "assistant", "message": {"content": [None]}})
        out({"type": "user", "message": {"content": [7]}})
        delta("survived")
        stop()
        result()
    elif text.startswith("permedit"):
        new = "\n".join(f"line{i}" for i in range(11)) + "\ncurl evil"
        out({"type": "control_request", "request_id": "e", "request": {"subtype": "can_use_tool", "tool_name": "Edit", "input": {"file_path": "/f", "old_string": "x", "new_string": new}}})
        log.write(json.dumps({"answer": read()}) + "\n")
        stop()
        result()
    elif text.startswith("permmcp"):
        body = "b" * 650 + " MCPTAIL"
        out({"type": "control_request", "request_id": "m", "request": {"subtype": "can_use_tool", "tool_name": "mcp__x__send", "input": {"body": body}}})
        log.write(json.dumps({"answer": read()}) + "\n")
        stop()
        result()
    elif text.startswith("think"):
        out({"type": "stream_event", "event": {"type": "content_block_start", "content_block": {"type": "thinking"}}})
        for chunk in ("**Weighing it**\nThe first idea looks ", "right to me. ", "SECONDSENTENCE is later."):
            out({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "thinking_delta", "thinking": chunk}}})
            time.sleep(0.25)
        stop()
        delta("answer")
        stop()
        result()
    elif text.startswith("toolflow"):
        out({"type": "stream_event", "event": {"type": "content_block_start", "content_block": {"type": "tool_use", "id": "tf", "name": "Bash"}}})
        stop()
        out({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "tf", "name": "Bash", "input": {"command": "sleep 9", "description": "Print two lines with pauses"}}]}})
        time.sleep(1.3)
        out({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "tf", "content": "OUTLINE1\nOUTLINE2"}]}})
        time.sleep(0.5)
        delta("done")
        stop()
        result()
    elif text.startswith("closeerr"):
        sys.stderr.close()
        os.close(2)
        delta("stderr closed")
        stop()
        result()
    elif text.startswith("permlong"):
        rid += 1
        cmd = "echo " + "a" * 150 + " && TAILMARK"
        out({"type": "control_request", "request_id": f"p{rid}", "request": {"subtype": "can_use_tool", "tool_name": "Bash", "input": {"command": cmd}}})
        log.write(json.dumps({"answer": read()}) + "\n")
        stop()
        result()
    elif text.startswith("perm"):
        rid += 1
        out({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": f"t{rid}", "name": "Bash", "input": {"command": "rm thing"}}]}})
        out({"type": "control_request", "request_id": f"p{rid}", "request": {"subtype": "can_use_tool", "tool_name": "Bash",
             "input": {"command": "rm thing"}, "permission_suggestions": [{"type": "setMode", "mode": "acceptEdits", "destination": "userSettings"}]}})
        ans = read()
        log.write(json.dumps({"answer": ans}) + "\n")
        delta("answered")
        stop()
        result()
    elif text.startswith("hang"):
        delta("stuck")
        time.sleep(0.2)
        continue  # never answers: only a force kill ends it
    elif text.startswith("die"):
        sys.exit(3)
    elif text.startswith("fail"):
        result(error=True, subtype="error_during_execution", text="credit balance too low")
    elif text.startswith("evil"):
        delta("safe\x1b]0;pwned\x07\x1b[2Jtext")
        stop()
        result()
    else:
        delta("reply to: ")
        delta(text.replace("\n", "|"))
        stop()
        result()
'''


class Driver:
    """Runs the real cac.py in a pty against the fake claude."""

    def __init__(self, tmp, args=(), cols=100, extra=None):
        self.tmp = tmp
        self.buf = b""
        self.master, slave = pty.openpty()
        import fcntl, struct
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, cols, 0, 0))
        env = dict(os.environ, PATH=tmp + "/bin:" + os.environ["PATH"], HOME=tmp,
                   CAC_TEST_LOG=tmp + "/log", COLUMNS=str(cols), LINES="40", **(extra or {}))
        env.pop("NO_COLOR", None)
        self.before = termios.tcgetattr(slave)
        self.slave = slave
        self.p = subprocess.Popen([sys.executable, "-I", SCRIPT, *args], stdin=slave, stdout=slave,
                                  stderr=slave, env=env, start_new_session=True)

    def pump(self, secs=0.05):
        r, _, _ = select.select([self.master], [], [], secs)
        if r:
            try:
                self.buf += os.read(self.master, 65536)
            except OSError:
                pass

    def text(self):
        return self.buf.decode("utf-8", "replace")

    def wait_for(self, needle, timeout=8):
        end = time.time() + timeout
        while time.time() < end:
            if needle in self.text():
                return True
            self.pump()
        raise AssertionError(f"never saw {needle!r} in:\n{self.text()[-1500:]}")

    def wait_count(self, needle, n, timeout=8):
        end = time.time() + timeout
        while time.time() < end:
            if self.text().count(needle) >= n:
                return
            self.pump()
        raise AssertionError(f"wanted {n}x {needle!r} in:\n{self.text()[-1500:]}")

    def settle(self, secs=0.3):
        end = time.time() + secs
        while time.time() < end:
            self.pump(0.02)

    def send(self, data):
        os.write(self.master, data if isinstance(data, bytes) else data.encode())

    def log(self):
        end = time.time() + 8  # the fake claude may still be starting
        while not os.path.exists(self.tmp + "/log") and time.time() < end:
            self.pump()
        with open(self.tmp + "/log") as f:
            return [json.loads(line) for line in f]

    def users(self):
        return [m["message"]["content"] for m in self.log() if m.get("type") == "user"]

    def tty_state(self):
        """The current termios state, minus PENDIN, which macOS sets itself on return to canonical."""
        state = termios.tcgetattr(self.slave)
        state[3] &= ~termios.PENDIN
        return state

    def finish(self):
        end = time.time() + 8
        while self.p.poll() is None and time.time() < end:
            self.pump()
        self.pump()
        if self.p.poll() is None:
            self.p.kill()
            raise AssertionError("cac did not exit")
        return self.p.returncode


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="cac-test-")
        os.makedirs(self.tmp + "/bin")
        path = self.tmp + "/bin/claude"
        with open(path, "w") as f:
            f.write(FAKE_CLAUDE.replace("#!/usr/bin/env python3", "#!" + sys.executable, 1))
        os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)
        self.d = None

    def tearDown(self):
        if self.d:
            if self.d.p.poll() is None:
                self.d.p.kill()
            self.d.p.wait()
            os.close(self.d.master)
            os.close(self.d.slave)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def start(self, *args):
        if self.d:  # a second run in one test
            self.d.p.wait()
            os.close(self.d.master)
            os.close(self.d.slave)
        self.d = Driver(self.tmp, args)
        self.d.wait_for("› ")
        return self.d


class TestKeyParser(unittest.TestCase):
    def test_split_utf8_and_sequences(self):
        p = cac.KeyParser()
        self.assertEqual(p.feed("తె".encode()[:2]), [])
        self.assertEqual(p.feed("తె".encode()[2:]), [("char", "తె")])
        self.assertEqual(p.feed(b"\x1b"), [])
        self.assertEqual(p.feed(b"["), [])
        self.assertEqual(p.feed(b"Z"), [("key", "shift-tab")])

    def test_bracketed_paste_split_across_reads(self):
        p = cac.KeyParser()
        self.assertEqual(p.feed(b"\x1b[200~line1\rline"), [])
        self.assertEqual(p.feed(b"2\x1b[20"), [])
        self.assertEqual(p.feed(b"1~\r"), [("paste", "line1\rline2"), ("key", "enter")])

    def test_unbracketed_burst_is_a_paste_not_two_sends(self):
        self.assertEqual(cac.KeyParser().feed(b"one\rtwo\r"), [("paste", "one\rtwo\r")])

    def test_typed_line_and_enter_stay_separate(self):
        self.assertEqual(cac.KeyParser().feed(b"hello\r"), [("char", "hello"), ("key", "enter")])

    def test_lone_esc_times_out(self):
        p = cac.KeyParser()
        p.feed(b"\x1b")
        self.assertIsNotNone(p.pending_since)
        self.assertEqual(p.flush(), [("key", "esc")])

    def test_unknown_sequence_is_swallowed(self):
        self.assertEqual(cac.KeyParser().feed(b"\x1b[99;9Xa"), [("char", "a")])


class TestRenderer(unittest.TestCase):
    def render(self, chunks, width=60):
        got = []
        old = shutil.get_terminal_size
        shutil.get_terminal_size = lambda *_: os.terminal_size((width, 24))
        try:
            r = cac.Renderer(cac.Style(False), got.append, True)
            for c in chunks:
                r.text(c)
            r.end()
        finally:
            shutil.get_terminal_size = old
        return "".join(got)

    def test_every_split_gives_the_same_output(self):
        text = "Hi **bold** and `code`\n\n# Head\n```py\nx = 1\n```\nafter * star"
        whole = self.render([text])
        for i in range(1, len(text)):
            self.assertEqual(self.render([text[:i], text[i:]]), whole, f"split at {i}")
        self.assertEqual(self.render(list(text)), whole)

    def test_markup_is_consumed(self):
        out = self.render(["Hi **bold** and `code`"])
        self.assertEqual(out, "\n◆ Hi bold and code\n")

    def test_fence_is_verbatim_at_column_zero(self):
        out = self.render(["see:\n```py\n    x = '**no**'  # `kept`\n```\ndone"])
        self.assertIn("\n    x = '**no**'  # `kept`\n", out)
        self.assertIn("╭ py", out)
        self.assertIn("╰", out)
        self.assertIn("\n  done", out)

    def test_unclosed_fence_still_terminates(self):
        self.assertTrue(self.render(["```\ncode"]).endswith("╰\n"))

    def test_wraps_on_words_with_indent(self):
        out = self.render(["word " * 30], width=40)
        lines = out.strip("\n").split("\n")
        self.assertGreater(len(lines), 2)
        for line in lines:
            self.assertLess(len(line.rstrip()), 40)
            self.assertFalse(line.rstrip().endswith("wor"))
        self.assertTrue(lines[1].startswith("  word"))

    def test_trailing_newlines_dropped_and_blank_kept(self):
        self.assertEqual(self.render(["\n\na\n\nb\n\n"]), "\n◆ a\n\n  b\n")

    def test_lone_star_and_backticks_mid_text(self):
        self.assertIn("2 * 3", self.render(["2 * 3"]))

    def test_arithmetic_stars_survive(self):
        self.assertIn("2 ** 10", self.render(["2 ** 10"]))
        self.assertEqual(self.render(["end **"]), "\n◆ end **\n")
        self.assertEqual(self.render(["**bold** ok"]), "\n◆ bold ok\n")

    def test_empty_block_prints_no_marker(self):
        self.assertEqual(self.render(["\n"]), "\n")


class TestHelpers(unittest.TestCase):
    def test_wrap_loses_nothing(self):
        text = "abc" * 50
        rows = cac.wrap_cells(text, 20)
        self.assertEqual("".join(rows), text)
        self.assertTrue(all(cac.text_width(r) <= 20 for r in rows))

    def test_emoji_presentation_counts_two_cells(self):
        self.assertEqual(cac.text_width("⚠\ufe0f"), 2)

    def test_fit_path_keeps_the_filename(self):
        out = cac.fit_path("/very/long/" * 20 + "name.py", 30)
        self.assertTrue(out.endswith("name.py"))
        self.assertLessEqual(cac.text_width(out), 30)


class TestSanitize(unittest.TestCase):
    def test_strips_escape_keeps_text(self):
        self.assertEqual(cac.sanitize("a\x1b]0;x\x07\x9bb\tc\nd"), "a]0;xb\tc\nd")


class TestEditor(unittest.TestCase):
    def ed(self):
        return cac.Editor(cac.Style(False), lambda s: None, lambda: None)

    def test_layout_wraps_and_tracks_cursor(self):
        e = self.ed()
        e.insert("a" * 25 + "\nbb")
        rows, r, c = e._layout(12)  # 12 wide, 1 spare, 2 prompt: 10... minimum room 10 cells
        self.assertEqual(rows, ["a" * 10, "a" * 10, "a" * 5, "bb"])
        self.assertEqual((r, c), (3, 2))

    def test_wide_chars_do_not_overflow(self):
        e = self.ed()
        e.insert("日" * 8)
        rows, _, _ = e._layout(14)
        self.assertTrue(all(cac.text_width(x) <= 11 for x in rows))

    def test_vertical_then_history(self):
        e = self.ed()
        e.history = ["old"]
        e.insert("a\nb")
        e.key("up")
        self.assertEqual(e.pos, 1)
        e.key("up")
        self.assertEqual(e.buf, "old")
        e.key("down")
        self.assertEqual(e.buf, "a\nb")

    def test_backslash_enter_continues(self):
        e = self.ed()
        e.insert("one\\")
        self.assertIsNone(e.key("enter"))
        self.assertEqual(e.buf, "one\n")
        e.insert("two")
        self.assertEqual(e.key("enter"), "submit")

    def test_kill_and_yank(self):
        e = self.ed()
        e.insert("hello world")
        e.key("ctrl-w")
        self.assertEqual(e.buf, "hello ")
        e.key("ctrl-y")
        self.assertEqual(e.buf, "hello world")

    def test_paste_normalizes_and_strips_control(self):
        e = self.ed()
        e.paste("a\r\nb\rc\x1b[31m")
        self.assertEqual(e.buf, "a\nb\nc[31m")


class TestLive(Base):
    def test_multiline_paste_is_one_message(self):
        d = self.start()
        d.send(b"\x1b[200~line one\nline two\nline three\x1b[201~")
        d.settle()
        self.assertEqual(d.users(), [])  # a paste alone must not send
        d.send("\r")
        d.wait_for("reply to: line one|line two|line three")
        self.assertEqual(d.users(), ["line one\nline two\nline three"])

    def test_your_text_and_reply_look_different(self):
        d = self.start()
        d.send("hi\r")
        d.wait_for("reply to: hi")
        t = d.text()
        self.assertIn("\x1b[1;36m› hi\x1b[0m", t)
        self.assertIn("\x1b[35m◆\x1b[0m ", t)

    def test_footer_shows_per_turn_cost_from_cumulative_total(self):
        d = self.start()
        d.send("one\r")
        d.wait_for("session $0.0100")
        d.send("two\r")
        d.wait_for("session $0.0200")
        self.assertEqual(d.text().count("$0.0100 · session"), 2)
        self.assertIn("1.5k in · 20 out", d.text())

    def test_starts_in_auto_with_session_and_system_note(self):
        d = self.start()
        d.send("/exit\r")
        d.finish()
        argv = d.log()[0]["argv"]
        self.assertEqual(argv[argv.index("--permission-mode") + 1], "auto")
        self.assertIn("--permission-prompt-tool", argv)
        self.assertIn("--session-id", argv)
        self.assertIn("--append-system-prompt", argv)

    def test_own_mode_flag_wins(self):
        d = self.start("--permission-mode", "plan")
        d.wait_for("plan › ")
        d.send("/exit\r")
        d.finish()
        self.assertEqual(d.log()[0]["argv"].count("--permission-mode"), 1)

    def test_resume_does_not_start_new_session(self):
        d = self.start("--resume", "abc")
        d.send("/exit\r")
        d.finish()
        self.assertNotIn("--session-id", d.log()[0]["argv"])
        self.assertIn("resume: cac --resume", d.text())

    def test_shift_tab_cycles_and_slash_mode_errors(self):
        d = self.start()
        d.send(b"\x1b[Z")
        d.wait_for("mode → default")
        d.send(b"\x1b[Z")
        d.wait_for("mode → acceptEdits")
        d.wait_for("acceptEdits › ")
        d.send("/mode junk\r")
        d.wait_for("must be one of")
        d.send("/mode plan\r")
        d.wait_for("plan › ")

    def test_ctrl_c_stops_reply_keeps_session(self):
        d = self.start()
        d.send("slow\r")
        d.wait_for("streaming")
        d.send(b"\x03")
        d.wait_for("stopped")
        d.wait_for("session $0.0100")
        d.send("again\r")
        d.wait_for("reply to: again")
        self.assertNotIn("⚠", d.text())

    def test_second_ctrl_c_force_quits_stuck_child(self):
        d = self.start()
        d.send("hang\r")
        d.wait_for("stuck")
        d.send(b"\x03")
        d.settle(0.3)
        d.send(b"\x03")  # a nervous double tap must not kill the session
        d.settle(0.3)
        self.assertIsNone(d.p.poll())
        self.assertNotIn("killing", d.text())
        d.settle(cac.FORCE_AFTER_SECONDS)
        d.send(b"\x03")
        d.finish()
        self.assertIn("killing", d.text())

    def test_ctrl_c_idle_clears_line_without_quitting(self):
        d = self.start()
        d.send("draft")
        d.wait_for("draft")
        d.send(b"\x03")
        d.settle()
        d.send(b"\x03")
        d.wait_for("to quit")
        self.assertIsNone(d.p.poll())

    def test_typing_during_reply_is_held_then_sent(self):
        d = self.start()
        d.send("slow\r")
        d.wait_for("streaming")
        d.send("next one")
        d.settle(0.1)
        d.send(b"\x03")
        d.wait_for("stopped")
        d.wait_for("next one")
        self.assertEqual(d.users(), ["slow"])
        d.send("\r")
        d.wait_for("reply to: next one")

    def test_permission_yes(self):
        d = self.start()
        d.send("perm\r")
        d.wait_for("Allow Bash?")
        d.wait_for("rm thing")
        d.settle(cac.PAUSE_SECONDS + 0.05)
        d.send("y")
        d.wait_for("answered")
        ans = [m for m in d.log() if "answer" in m][0]["answer"]["response"]["response"]
        self.assertEqual(ans["behavior"], "allow")
        self.assertEqual(ans["updatedInput"], {"command": "rm thing"})
        self.assertNotIn("updatedPermissions", ans)

    def test_permission_no(self):
        d = self.start()
        d.send("perm\r")
        d.wait_for("Allow Bash?")
        d.settle(cac.PAUSE_SECONDS + 0.05)
        d.send("n")
        d.wait_for("answered")
        ans = [m for m in d.log() if "answer" in m][0]["answer"]["response"]["response"]
        self.assertEqual(ans["behavior"], "deny")

    def test_always_never_writes_to_settings(self):
        d = self.start()
        d.send("perm\r")
        d.wait_for("Allow Bash?")
        d.settle(cac.PAUSE_SECONDS + 0.05)
        d.send("a")
        d.wait_for("answered")
        ans = [m for m in d.log() if "answer" in m][0]["answer"]["response"]["response"]
        self.assertEqual({p["destination"] for p in ans["updatedPermissions"]}, {"session"})

    def test_typeahead_cannot_approve(self):
        d = self.start()
        d.send("perm\r")
        d.settle(0.02)  # separate reads, or it's one burst and counts as a paste
        d.send("y")  # already in flight when the prompt appears
        d.wait_for("Allow Bash?")
        d.settle(cac.PAUSE_SECONDS + 0.2)
        self.assertEqual([m for m in d.log() if "answer" in m], [])
        d.send(b"\x1b[200~y\x1b[201~")  # neither can a paste
        d.settle(cac.PAUSE_SECONDS + 0.2)
        self.assertEqual([m for m in d.log() if "answer" in m], [])
        d.send("n")
        d.wait_for("answered")

    def test_typing_a_sentence_cannot_approve(self):
        d = self.start()
        d.send("perm\r")
        d.wait_for("Allow Bash?")
        d.settle(cac.GATE_SECONDS + 0.05)
        for ch in "ok so yes":  # still typing the next message, at human speed
            d.send(ch)
            d.settle(0.1)
        self.assertEqual([m for m in d.log() if "answer" in m], [])
        d.settle(cac.PAUSE_SECONDS + 0.05)
        d.send("n")
        d.wait_for("answered")
        d.wait_for("ok so yes")  # nothing typed was lost

    def test_always_says_what_it_grants(self):
        d = self.start()
        d.send("perm\r")
        d.wait_for("[a] this session: switch to acceptEdits mode")

    def test_edit_approval_shows_the_tail(self):
        d = self.start()
        d.send("permedit\r")
        d.wait_for("+ curl evil")
        d.settle(cac.PAUSE_SECONDS + 0.05)
        d.send("n")
        d.wait_for("session $")

    def test_tool_approval_shows_the_whole_input(self):
        d = self.start()
        d.send("permmcp\r")
        d.wait_for("Allow mcp__x__send?")
        d.settle(0.3)
        self.assertIn("MCPTAIL", d.text().replace("\r\n    ", ""))  # it wraps, and may wrap inside the word
        d.settle(cac.PAUSE_SECONDS + 0.05)
        d.send("n")
        d.wait_for("session $")

    def test_request_while_idle_does_not_wedge(self):
        d = self.start()
        d.send("idlereq\r")
        d.wait_for("Allow Bash?")
        d.settle(cac.PAUSE_SECONDS + 0.05)
        d.send("n")
        d.settle(0.2)
        d.send("after\r")
        d.wait_for("reply to: after")

    def test_output_while_idle_releases_the_keyboard(self):
        d = self.start()
        d.send("late\r")
        d.wait_for("late text")
        d.settle(cac.WAKE_RELEASE_SECONDS + 0.4)
        d.send("after\r")
        d.wait_for("reply to: after")

    def test_result_during_prompt_keeps_the_prompt(self):
        d = self.start()
        d.send("promptresult\r")
        d.wait_for("session $")
        d.settle(cac.PAUSE_SECONDS + 0.05)
        d.send("n")
        d.settle(0.2)
        self.assertEqual([m for m in d.log() if "answer" in m][0]["answer"]["response"]["response"]["behavior"], "deny")
        d.send("after\r")
        d.wait_for("reply to: after")

    def test_malformed_events_do_not_end_the_session(self):
        d = self.start()
        d.send("badjson\r")
        d.wait_for("survived")
        d.send("after\r")
        d.wait_for("reply to: after")

    def test_malformed_events_are_ignored_quietly(self):
        d = self.start()
        d.send("badjson\r")
        d.wait_for("survived")
        self.assertNotIn("Error on a", d.text())

    def test_closed_stderr_does_not_spin(self):
        def cpu(pid):
            out = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
            minutes, seconds = out.split(":")
            return int(minutes) * 60 + float(seconds)
        d = self.start()
        d.send("closeerr\r")
        d.wait_for("session $")
        before = cpu(d.p.pid)
        d.settle(1.5)
        self.assertLess(cpu(d.p.pid) - before, 0.5)
        d.send("after\r")
        d.wait_for("reply to: after")

    def test_oversized_entry_stays_out_of_history(self):
        d = self.start()
        d.send("small one\r")
        d.wait_for("reply to: small one")
        big = "z" * (cac.HISTORY_ENTRY_MAX + 10)
        d.send(b"\x1b[200~" + big.encode() + b"\x1b[201~")
        d.settle(0.3)
        d.send("\r")
        d.wait_count("session $", 2)
        d.settle(0.2)
        mark = len(d.text())
        d.send(b"\x1b[A")
        d.settle(0.3)
        self.assertIn("small one", d.text()[mark:])
        self.assertNotIn("zzz", d.text()[mark:])
        with open(self.tmp + "/.local/state/cac/history.jsonl") as f:
            self.assertNotIn("zzz", f.read())

    def test_concise_shows_thinking_gist_only(self):
        d = self.start()
        d.send("think\r")
        d.wait_for("session $")
        self.assertIn("✻ The first idea looks right to me.", d.text())
        self.assertNotIn("✻ Weighing", d.text())  # the heading isn't the gist
        final = d.text().split("✻", 1)[1]
        self.assertNotIn("SECONDSENTENCE", final)  # not in the scrollback in concise view

    def test_live_line_shows_latest_thinking(self):
        d = self.start()
        d.send("think\r")
        d.wait_for("thinking: The first idea")

    def test_detailed_shows_everything_and_ctrl_o_toggles(self):
        d = self.start()
        d.send(b"\x0f")
        d.wait_for("view → detailed")
        d.send("think\r")
        d.wait_for("session $")
        self.assertIn("SECONDSENTENCE", d.text().split("✻", 1)[1])
        d.send("toolflow\r")
        d.wait_for("OUTLINE1")
        d.wait_for("OUTLINE2")
        d.wait_count("session $", 2)
        d.send("/view concise\r")
        d.wait_for("view → concise")

    def test_tool_output_hidden_when_concise(self):
        d = self.start()
        d.send("toolflow\r")
        d.wait_for("session $")
        self.assertNotIn("OUTLINE1", d.text())

    def test_live_line_says_what_the_tool_is_doing_then_moves_on(self):
        d = self.start()
        d.send("toolflow\r")
        d.wait_for("Bash: Print two lines with pauses 1s")  # its own clock, not the turn's
        d.wait_for("thinking 0s")  # finished, so no longer "Bash"
        d.wait_for("1 tool")

    def test_live_line_never_wraps(self):
        self.d = Driver(self.tmp, (), cols=30)
        self.d.wait_for("› ")
        self.d.send("toolflow\r")
        self.d.wait_for("session $")
        frames = re.findall(r"\r\x1b\[2m([⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] [^\x1b]*)\x1b", self.d.text())
        self.assertTrue(frames)
        for frame in frames:
            self.assertLess(cac.text_width(frame), 30, frame)

    def test_asks_for_thinking_text_unless_told_otherwise(self):
        d = self.start()
        argv = d.log()[0]["argv"]
        self.assertEqual(argv[argv.index("--thinking-display") + 1], "summarized")
        d.send("/exit\r")
        d.finish()
        d = self.start("--thinking-display", "omitted")
        d.settle(0.3)
        self.assertEqual(d.log()[-1]["argv"].count("--thinking-display"), 1)

    def test_claude_without_the_flag_still_works(self):
        self.d = Driver(self.tmp, (), extra={"CAC_TEST_REJECT": "1"})
        self.d.wait_for("› ")
        self.d.send("hi\r")
        self.d.wait_for("reply to: hi")
        self.assertNotIn("unknown option", self.d.text())
        runs = [m["argv"] for m in self.d.log() if "argv" in m]
        self.assertEqual(len(runs), 2)  # rejected once, then restarted without the flag
        self.assertIn("--thinking-display", runs[0])
        self.assertNotIn("--thinking-display", runs[1])
        self.assertEqual(self.d.users(), ["hi"])  # the message wasn't lost or doubled

    def test_resume_without_id_is_a_clean_error(self):
        env = dict(os.environ, PATH=self.tmp + "/bin:" + os.environ["PATH"], HOME=self.tmp, CAC_TEST_LOG=self.tmp + "/log")
        for args in (["--resume"], ["--resume", "--model", "haiku"]):
            r = subprocess.run([sys.executable, "-I", SCRIPT, *args], input=b"", capture_output=True, env=env, timeout=10)
            self.assertEqual(r.returncode, 2)
            self.assertIn(b"needs a session id", r.stderr)

    def test_approval_shows_the_whole_command(self):
        d = self.start()
        d.send("permlong\r")
        d.wait_for("TAILMARK")
        d.settle(cac.GATE_SECONDS + 0.05)
        self.assertNotIn("[a]", d.text())  # no suggestions, nothing to remember
        d.settle(cac.PAUSE_SECONDS)
        d.send("a")  # so "always" must not count as an answer
        d.settle(cac.PAUSE_SECONDS + 0.1)
        self.assertEqual([m for m in d.log() if "answer" in m], [])
        d.send("n")
        d.wait_for("session $")

    def test_ctrl_c_at_permission_denies(self):
        d = self.start()
        d.send("perm\r")
        d.wait_for("Allow Bash?")
        d.send(b"\x03")
        d.wait_for("answered")
        ans = [m for m in d.log() if "answer" in m][0]["answer"]["response"]["response"]
        self.assertEqual(ans["behavior"], "deny")

    def test_error_is_shown(self):
        d = self.start()
        d.send("fail\r")
        d.wait_for("⚠ credit balance too low")

    def test_child_death_is_reported_and_terminal_restored(self):
        d = self.start()
        d.send("die\r")
        self.assertEqual(d.finish(), 3)
        self.assertIn("claude exited with code 3", d.text())
        self.assertEqual(d.tty_state(), d.before)
        self.assertIn("\x1b[?2004l", d.text())

    def test_exit_restores_terminal(self):
        d = self.start()
        d.send("hello\r")
        d.wait_for("reply to: hello")
        d.send(b"\x04")
        self.assertEqual(d.finish(), 0)
        self.assertEqual(d.tty_state(), d.before)
        t = d.text()
        self.assertIn("\x1b[?2004l", t)
        self.assertGreater(t.rfind("\x1b[?25h"), t.rfind("\x1b[?25l"))
        self.assertIn("resume: cac --resume", t)

    def test_sigterm_restores_terminal(self):
        d = self.start()
        d.p.send_signal(signal.SIGTERM)
        d.finish()
        self.assertEqual(d.tty_state(), d.before)

    def test_escape_sequences_in_reply_are_neutralized(self):
        d = self.start()
        d.send("evil\r")
        d.wait_for("session $")
        self.assertNotIn("\x1b]0;pwned", d.text())
        self.assertNotIn("\x1b[2J", d.text())

    def test_footer_fits_a_narrow_terminal(self):
        self.d = Driver(self.tmp, (), cols=30)
        self.d.wait_for("› ")
        self.d.send("hi\r")
        self.d.wait_for("…")
        line = [x for x in self.d.text().split("\n") if "session $" in x or "$0.01" in x][0]
        visible = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", line).strip("\r")
        self.assertLess(cac.text_width(visible), 30)

    def test_noise_line_hidden(self):
        d = self.start()
        d.send("hi\r")
        d.wait_for("reply to: hi")
        self.assertNotIn("connectors are disabled", d.text())

    def test_history_recall_persists_across_runs(self):
        d = self.start()
        d.send("remember me\r")
        d.wait_for("reply to: remember me")
        d.send("/exit\r")
        d.finish()
        path = self.tmp + "/.local/state/cac/history.jsonl"
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        d = self.start()
        d.settle(0.2)
        mark = len(d.text())
        d.send(b"\x1b[A")
        d.settle(0.2)
        self.assertIn("/exit", d.text()[mark:])
        d.send(b"\x1b[A")
        d.settle(0.2)
        self.assertIn("remember me", d.text()[mark:])


class TestPiped(Base):
    def run_cac(self, stdin, *args):
        env = dict(os.environ, PATH=self.tmp + "/bin:" + os.environ["PATH"], HOME=self.tmp,
                   CAC_TEST_LOG=self.tmp + "/log")
        return subprocess.run([sys.executable, "-I", SCRIPT, *args], input=stdin.encode(),
                              capture_output=True, env=env, timeout=20)

    def test_plain_output_and_one_message_per_line(self):
        r = self.run_cac("first\nsecond\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.decode(), "reply to: first\nreply to: second\n")
        self.assertNotIn(b"\x1b", r.stdout)

    def test_permission_is_denied_when_nobody_is_there(self):
        self.run_cac("perm\n")
        with open(self.tmp + "/log") as f:
            answers = [json.loads(x) for x in f if '"answer"' in x]
        self.assertEqual(answers[0]["answer"]["response"]["response"]["behavior"], "deny")

    def test_closed_stdout_is_quiet(self):
        env = dict(os.environ, PATH=self.tmp + "/bin:" + os.environ["PATH"], HOME=self.tmp, CAC_TEST_LOG=self.tmp + "/log")
        r = subprocess.run(f"printf 'a\\nb\\n' | {sys.executable} -I {SCRIPT} | head -c 3",
                           shell=True, capture_output=True, env=env, timeout=20)
        self.assertNotIn(b"Traceback", r.stderr)
        self.assertNotIn(b"Exception ignored", r.stderr)

    def test_error_sets_exit_code(self):
        r = self.run_cac("fail\n")
        self.assertEqual(r.returncode, 1)
        self.assertIn("credit balance", r.stderr.decode())


class TestSecretsStayOutOfArgv(unittest.TestCase):
    """Anything on a command line is readable by every local process through `ps`."""

    KEY = "sk-planted-secret-value"
    FAKE_CURL = """#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
delivered = ""
for i, a in enumerate(args):
    if a == "-H" and args[i + 1].startswith("@"):
        delivered += open(args[i + 1][1:]).read()
    if a in ("--data-binary", "-d") and args[i + 1] == "@-":
        delivered += sys.stdin.read()
with open(os.environ["FAKE_CURL_LOG"], "a") as f:
    f.write(json.dumps({"argv": args, "delivered": delivered}) + "\\n")
print(json.dumps({"content": [{"type": "text", "text": "ok"}], "data": []}), end="")
"""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="cac-argv-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        os.makedirs(self.tmp + "/bin")
        for name, body in (("curl", self.FAKE_CURL.replace("#!/usr/bin/env python3", "#!" + sys.executable, 1)),
                           ("security", f"#!/bin/sh\nprintf %s {self.KEY}\n")):
            with open(f"{self.tmp}/bin/{name}", "w") as f:
                f.write(body)
            os.chmod(f"{self.tmp}/bin/{name}", 0o755)

    def run_in_config(self, script):
        log = self.tmp + "/curl.log"
        env = dict(os.environ, PATH=self.tmp + "/bin:" + os.environ["PATH"], HOME=self.tmp, TMPDIR=self.tmp, FAKE_CURL_LOG=log)
        config = os.path.join(ROOT, "claude_config.zsh")
        r = subprocess.run(["zsh", "-f", "-c", f"source {config} >/dev/null 2>&1; {script}"], stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, env=env, timeout=30)
        with open(log) as f:
            return r, [json.loads(line) for line in f]

    def check(self, calls):
        self.assertTrue(calls, "curl was never called")
        for call in calls:
            self.assertNotIn(self.KEY, " ".join(call["argv"]))
            self.assertIn(self.KEY, call["delivered"])  # still sent, just not on the command line

    def test_ask_keeps_key_and_prompt_off_the_command_line(self):
        r, calls = self.run_in_config("ask 'my private question'")
        self.assertEqual(r.stdout.strip(), "ok", r.stderr)
        self.check(calls)
        self.assertNotIn("my private question", " ".join(calls[0]["argv"]))
        self.assertIn("my private question", calls[0]["delivered"])

    def test_ask_keeps_the_prompt_off_every_command_line(self):
        real_jq = shutil.which("jq")
        log = self.tmp + "/jq.log"
        with open(self.tmp + "/bin/jq", "w") as f:
            f.write(f'#!/bin/sh\nprintf "%s\\n" "$*" >> {log}\nexec {real_jq} "$@"\n')
        os.chmod(self.tmp + "/bin/jq", 0o755)
        secret = 'my "private" question\nsecond line'
        r, calls = self.run_in_config(f"ask {shlex.quote(secret)}")
        self.assertEqual(r.stdout.strip(), "ok", r.stderr)
        with open(log) as f:
            self.assertNotIn("private", f.read())
        self.assertNotIn("private", " ".join(calls[0]["argv"]))
        body = json.loads(calls[0]["delivered"].split("\n", 1)[1])  # the header comes first
        self.assertEqual(body["messages"][0]["content"], secret)  # delivered exactly, quotes and newline intact

    def test_ask_with_piped_input_too(self):
        log = self.tmp + "/curl.log"
        env = dict(os.environ, PATH=self.tmp + "/bin:" + os.environ["PATH"], HOME=self.tmp, TMPDIR=self.tmp, FAKE_CURL_LOG=log)
        config = os.path.join(ROOT, "claude_config.zsh")
        r = subprocess.run(["zsh", "-f", "-c", f"source {config} >/dev/null 2>&1; ask summarize"], input="piped text\n",
                           capture_output=True, text=True, env=env, timeout=30)
        self.assertEqual(r.stdout.strip(), "ok", r.stderr)
        with open(log) as f:
            body = json.loads(json.loads(f.readline())["delivered"].split("\n", 1)[1])
        self.assertEqual(body["messages"][0]["content"], "summarize\n\npiped text")

    def test_openrouter_probe(self):
        _, calls = self.run_in_config(f"OPENROUTER_API_KEY={self.KEY} OPENROUTER_BASE_URL=http://x; _orf_ratelimited some/model")
        self.check(calls)

    def test_openrouter_catalog(self):
        _, calls = self.run_in_config(f"OPENROUTER_API_KEY={self.KEY} OPENROUTER_BASE_URL=http://x; _orf_models_json")
        self.check(calls)


if __name__ == "__main__":
    unittest.main(verbosity=1)
