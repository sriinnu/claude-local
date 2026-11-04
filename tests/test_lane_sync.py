#!/usr/bin/env python3
"""Tests for scripts/lane-sync.py. Stdlib only and free: a fake provider stands in for the real ones.

    python3 tests/test_lane_sync.py
"""
import http.server
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

sys.dont_write_bytecode = True
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "lane-sync.py")
spec = importlib.util.spec_from_file_location("lane_sync", SCRIPT)
ls = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ls)

GOOD = ls._good_stream()
BLANK = ls._sse({"type": "content_block_start", "content_block": {"type": "tool_use", "id": "", "name": ""}})


class Fake(http.server.BaseHTTPRequestHandler):
    """Serves a model list and /v1/messages; behaviour per model comes from `plan`."""
    ids = []
    plan = {}      # model -> "good" | "no-text" | "history-blank" | "400" | "429" | "401"
    calls = []
    err = "nope"

    def log_message(self, *_):
        pass

    def _send(self, code, body):
        data = body.encode()
        self.send_response(code)
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._send(200, json.dumps({"data": [{"id": i} for i in Fake.ids]}))

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        model, stream = body["model"], body.get("stream")
        history = len(body["messages"]) > 1
        Fake.calls.append(model)
        how = Fake.plan.get(model, "good")
        if how.isdigit():
            return self._send(int(how), json.dumps({"error": {"message": Fake.err}}))
        if not stream:
            return self._send(200, "{}")
        if how == "no-text":
            return self._send(200, ls._sse({"type": "content_block_start",
                                            "content_block": {"type": "tool_use", "id": "a", "name": "Bash"}}))
        if how == "history-blank" and history:
            return self._send(200, BLANK)
        self._send(200, GOOD)


class Base(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fake)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.url = f"http://127.0.0.1:{cls.srv.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        Fake.ids, Fake.plan, Fake.calls, Fake.err = ["org/old"], {}, [], "nope"
        self.lanes = {"fake": {"base": self.url, "key": "X", "list": self.url + "/v1/models", "kosha": "", "control": None}}
        self.env = {**os.environ, "LANE_SYNC_NO_SPAWN": "1", "LANE_SYNC_STATE_DIR": self.tmp, "LANE_SYNC_TEST_KEY": "k",
                    "LANE_SYNC_TEST_LANES": json.dumps(self.lanes), "XDG_CACHE_HOME": self.tmp,
                    "LANE_SYNC_KOSHA": os.path.join(self.tmp, "none.json")}
        os.environ.update({k: self.env[k] for k in ("LANE_SYNC_STATE_DIR", "LANE_SYNC_TEST_KEY", "LANE_SYNC_TEST_LANES", "LANE_SYNC_KOSHA")})

    def run_cli(self, *args, env=None):
        return subprocess.run([sys.executable, "-I", SCRIPT, *args], capture_output=True, text=True,
                              env=env or self.env, timeout=30)

    def banner(self, *slots, env=None):
        return self.run_cli("banner", "fake", *(slots or ("org/old", "org/old", "org/old")), env=env)

    def state(self):
        with open(os.path.join(self.tmp, "fake.json")) as f:
            return json.load(f)


class Classifiers(unittest.TestCase):
    def test_selftest_catches_every_planted_failure(self):
        self.assertEqual(ls.selftest(), [])

    def test_blank_tool_is_flagged_in_both_turns(self):
        self.assertTrue(ls.classify_single(BLANK))
        self.assertTrue(ls.classify_history(BLANK))

    def test_clean_stream_passes(self):
        self.assertEqual(ls.classify_single(GOOD), [])
        self.assertEqual(ls.classify_history(GOOD), [])


class Ladder(Base):
    def test_verdicts(self):
        Fake.plan = {"a": "good", "b": "no-text", "c": "history-blank", "d": "400", "e": "429", "f": "401"}
        got = {m: ls.ladder("fake", "k", m)[0] for m in "abcdef"}
        self.assertEqual(got, {"a": "pass", "b": "broken", "c": "broken", "d": "not_served", "e": None, "f": "auth"})

    def test_quota_is_not_a_verdict_about_the_model(self):
        # A 400 that says "insufficient balance" is the wallet talking, not the model.
        class H(Fake):
            def do_POST(self):
                self.rfile.read(int(self.headers["content-length"]))
                self._send(400, json.dumps({"error": {"message": "Insufficient balance"}}))
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.shutdown)
        os.environ["LANE_SYNC_TEST_LANES"] = json.dumps({"fake": {**self.lanes["fake"], "base": f"http://127.0.0.1:{srv.server_port}"}})
        self.assertIsNone(ls.ladder("fake", "k", "m")[0])

    def test_budget_stops_full_ladder_but_keeps_it_pending(self):
        v, why = ls.ladder("fake", "k", "a", ls.Budget(0, 5), guess=True)
        self.assertIsNone(v)
        self.assertIn("pending", why)

    def test_a_listed_id_skips_the_smoke_once_ladders_run_out(self):
        Fake.calls = []
        self.assertEqual(ls.ladder("fake", "k", "a", ls.Budget(0, 5)), (None, "out of budget"))
        self.assertEqual(Fake.calls, [])


class Banner(Base):
    def test_first_run_is_a_baseline_not_a_flood(self):
        Fake.ids = ["org/old", "org/two"]
        err = self.banner().stderr
        self.assertIn("baseline", err)
        self.assertNotIn("+ org/two", err)

    def test_second_launch_names_the_new_id_and_the_gone_one(self):
        self.banner()
        Fake.ids = ["org/new"]
        err = self.banner().stderr
        self.assertIn("+ org/new", err)
        self.assertIn("- org/old", err)
        self.assertIn("no longer lists", err)
        self.assertNotIn("+ org/new", self.banner().stderr)   # told once

    def test_stdout_is_three_slots_and_a_one_line_picker(self):
        env = {**self.env, "LANE_PICKER": '{"modelPicker":{"options":[\n{"model":"a"}]}}'}
        out = self.banner("a", "b", "c", env=env).stdout.splitlines()
        self.assertEqual(out[:3], ["a", "b", "c"])
        self.assertEqual(len(out), 4)
        self.assertEqual(json.loads(out[3])["modelPicker"]["options"], [{"model": "a"}])

    def test_passing_id_reaches_the_picker_and_broken_does_not(self):
        self.banner()
        Fake.ids = ["org/old", "org/ok", "org/bad"]
        Fake.plan = {"org/bad": "no-text"}
        self.banner()
        self.assertEqual(self.run_cli("test", "fake").returncode, 0)
        env = {**self.env, "LANE_PICKER": '{"modelPicker":{"options":[{"model":"org/old"}]}}'}
        r = self.banner(env=env)
        rows = [o["model"] for o in json.loads(r.stdout.splitlines()[3])["modelPicker"]["options"]]
        self.assertIn("org/ok", rows)
        self.assertNotIn("org/bad", rows)
        self.assertIn("✓ org/ok", r.stderr)
        self.assertIn("✗ org/bad", r.stderr)

    def test_hostile_id_never_reaches_the_terminal(self):
        Fake.ids = ["org/old", "evil\x1b]0;pwn\x07", "x; rm -rf ~"]
        r = self.banner()
        self.banner()
        self.assertNotIn("evil", r.stderr + r.stdout)
        self.assertNotIn("rm -rf", json.dumps(self.state()))

    def test_unknown_lane_stays_silent(self):
        r = self.run_cli("banner", "lcp-local", "a", "b", "c")
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))

    def test_dead_provider_keeps_the_launch_going(self):
        self.banner()
        env = {**self.env, "LANE_SYNC_TEST_LANES": json.dumps({"fake": {**self.lanes["fake"], "list": "http://127.0.0.1:9/x"}})}
        r = self.banner("a", "b", "c", env=env)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.splitlines()[:3], ["a", "b", "c"])
        self.assertIn("unreachable", r.stderr)

    def test_corrupt_state_keeps_the_launch_going(self):
        with open(os.path.join(self.tmp, "fake.json"), "w") as f:
            f.write("{not json")
        r = self.banner("a", "b", "c")
        self.assertEqual(r.stdout.splitlines()[:3], ["a", "b", "c"])


class BaselineIsNotNews(Base):
    def test_old_ids_stay_out_of_the_picker_and_the_banner_when_they_pass(self):
        Fake.ids = ["org/ancient"]
        self.banner()
        self.run_cli("test", "fake")
        r = self.banner(env={**self.env, "LANE_PICKER": '{"modelPicker":{"options":[]}}'})
        self.assertNotIn("org/ancient", r.stdout)
        self.assertNotIn("org/ancient", r.stderr)
        self.assertIn("1 verified", r.stderr)

    def test_a_seeded_failure_that_now_passes_is_news(self):
        env_lanes = {"siliconflow": {**self.lanes["fake"]}}
        env = {**self.env, "LANE_SYNC_TEST_LANES": json.dumps(env_lanes)}
        Fake.ids = ["deepseek-ai/DeepSeek-V4.1-Flash-1017"]
        self.run_cli("banner", "siliconflow", "a", "b", "c", env=env)
        self.run_cli("test", "siliconflow", "--limit", "20", env=env)
        err = self.run_cli("banner", "siliconflow", "a", "b", "c", env=env).stderr
        self.assertIn("✓ deepseek-ai/DeepSeek-V4.1-Flash-1017", err)


class Accept(Base):
    def setUp(self):
        super().setUp()
        self.banner()
        Fake.ids = ["org/old", "org/ok"]
        self.banner()
        self.run_cli("test", "fake")

    def test_default_moves_only_on_accept_and_reverts(self):
        self.assertEqual(self.banner().stdout.splitlines()[0], "org/old")
        self.assertEqual(self.run_cli("accept", "fake", "org/ok").returncode, 0)
        self.assertEqual(self.banner().stdout.splitlines()[0], "org/ok")
        self.run_cli("revert", "fake")
        self.assertEqual(self.banner().stdout.splitlines()[0], "org/old")

    def test_unverified_id_is_refused(self):
        r = self.run_cli("accept", "fake", "org/never")
        self.assertEqual(r.returncode, 1)
        self.assertIn("isn't verified", r.stderr)

    def test_accepted_id_that_breaks_later_falls_back(self):
        self.run_cli("accept", "fake", "org/ok")
        st = self.state()
        st["models"]["org/ok"]["verdict"] = "broken"
        with open(os.path.join(self.tmp, "fake.json"), "w") as f:
            json.dump(st, f)
        r = self.banner()
        self.assertEqual(r.stdout.splitlines()[0], "org/old")
        self.assertIn("no longer passes", r.stderr)


class Control(Base):
    def test_failing_control_discards_the_run(self):
        env_lanes = {"fake": {**self.lanes["fake"], "control": "org/ctl"}}
        env = {**self.env, "LANE_SYNC_TEST_LANES": json.dumps(env_lanes)}
        Fake.ids = ["org/ctl", "org/x"]
        Fake.plan = {"org/ctl": "no-text"}
        self.banner(env=env)
        self.run_cli("test", "fake", env=env)
        st = self.state()
        self.assertIsNone(st["models"]["org/x"]["verdict"])
        self.assertTrue(any(e["kind"] == "harness" for e in st["events"]))
        self.assertNotIn("org/x", Fake.calls)


class Guesses(Base):
    def test_plan_without_list_tests_guesses_and_a_miss_stays_quiet(self):
        reg = os.path.join(self.tmp, "reg.json")
        with open(reg, "w") as f:
            json.dump({"models": [{"modelId": "real", "providerId": "p", "mode": "chat"},
                                  {"modelId": "miss", "providerId": "p", "mode": "chat"},
                                  {"modelId": "pic", "providerId": "p", "mode": "image"}]}, f)
        lanes = {"fake": {**self.lanes["fake"], "list": None, "kosha": "p"}}
        env = {**self.env, "LANE_SYNC_TEST_LANES": json.dumps(lanes), "LANE_SYNC_KOSHA": reg}
        Fake.plan = {"miss": "400"}
        self.banner(env=env)
        self.run_cli("test", "fake", env=env)
        err = self.banner(env=env).stderr
        self.assertIn("✓ real", err)
        self.assertNotIn("miss", err)
        self.assertNotIn("pic", json.dumps(self.state()["models"]))


class Secrets(Base):
    def test_a_key_in_an_error_message_is_redacted(self):
        self.assertNotIn("abcd1234", ls.clean("bad key " + "sk" + "-abcd1234efgh"))

    def test_key_never_appears_in_state_or_output(self):
        env = {**self.env, "LANE_SYNC_TEST_KEY": "sekret-value"}
        r = self.banner(env=env)
        self.assertNotIn("sekret-value", r.stdout + r.stderr + json.dumps(self.state()))


class ReviewFindings(Base):
    """Each of these failed before the fix (independent review, 2026-11-04)."""

    def test_lane_without_a_picker_gets_no_settings_flag(self):
        self.assertEqual(len(self.banner("a", "b", "c").stdout.splitlines()), 3)

    def test_unparsable_base_picker_keeps_stdout_to_one_line_each(self):
        env = {**self.env, "LANE_PICKER": '{"broken":\n"json'}
        self.assertEqual(len(self.banner("a", "b", "c", env=env).stdout.splitlines()), 3)

    def test_escape_bytes_in_a_provider_error_never_reach_the_terminal(self):
        self.banner()
        Fake.ids = ["org/old", "org/x"]
        Fake.plan = {"org/x": "400"}
        Fake.err = "nope \x1b]0;pwned\x07\x1b[31mRED"
        self.banner()
        self.run_cli("test", "fake")
        err = self.banner().stderr + self.run_cli("show", "fake").stdout
        self.assertIn("org/x", err)
        self.assertNotIn("\x1b", err)
        self.assertNotIn("\\u001b", open(os.path.join(self.tmp, "fake.json")).read())

    def test_a_key_echoed_by_the_provider_is_scrubbed_everywhere(self):
        secret = "vck" + "_sekretvalue99"   # built here so no key-shaped literal is committed
        env = {**self.env, "LANE_SYNC_TEST_KEY": secret}
        self.banner(env=env)
        Fake.ids = ["org/old", "org/x"]
        Fake.plan = {"org/x": "400"}
        Fake.err = f"bad header Authorization: Bearer {secret}"
        self.banner(env=env)
        out = self.run_cli("test", "fake", env=env)
        later = self.banner(env=env)
        blob = out.stdout + out.stderr + later.stderr + open(os.path.join(self.tmp, "fake.json")).read()
        self.assertIn("org/x", blob)
        self.assertNotIn(secret, blob)

    def test_deadline_during_the_state_read_leaves_the_file_alone(self):
        self.banner()
        path = os.path.join(self.tmp, "fake.json")
        before = open(path).read()
        real = ls.json.load
        def boom(*_a, **_k):
            raise ls.LaneDeadline
        ls.json.load = boom
        self.addCleanup(setattr, ls.json, "load", real)
        with self.assertRaises(ls.LaneDeadline):
            with ls.locked_state("fake"):
                pass
        ls.json.load = real
        self.assertEqual(open(path).read(), before)

    def test_corrupt_state_is_set_aside_not_overwritten(self):
        path = os.path.join(self.tmp, "fake.json")
        with open(path, "w") as f:
            f.write("{not json")
        self.banner()
        aside = [n for n in os.listdir(self.tmp) if ".corrupt-" in n]
        self.assertEqual(len(aside), 1)
        self.assertEqual(open(os.path.join(self.tmp, aside[0])).read(), "{not json")

    def test_non_object_sse_payload_is_ignored(self):
        self.assertTrue(ls.classify_single("data: 1\ndata: []"))
        self.assertTrue(ls.classify_history("data: 1"))

    def test_sweep_survives_one_lane_blowing_up(self):
        lanes = {"one": self.lanes["fake"], "two": self.lanes["fake"]}
        os.environ["LANE_SYNC_TEST_LANES"] = json.dumps(lanes)
        seen = []
        def fake_run(lane):
            seen.append(lane)
            raise RuntimeError("boom")
        real = ls.run_tests
        ls.run_tests = fake_run
        self.addCleanup(setattr, ls, "run_tests", real)
        ls.cmd_sweep(None)
        self.assertEqual(seen, ["one", "two"])

    def test_ladder_budget_is_not_spent_on_results_thrown_away(self):
        Fake.ids = [f"org/m{i:02d}" for i in range(13)]
        self.banner()
        Fake.calls = []
        self.run_cli("test", "fake", "--limit", "2")
        self.assertLessEqual(len(Fake.calls), 12)   # 2 ladders x 5 calls, plus at most a thread race

    def test_real_lane_names_resolve_and_unknown_ones_leave_no_files(self):
        for name, lane in {"qwen-cc": "qwen", "qwen-ds": "qwen", "vai": "vercel", "orf": "openrouter",
                           "kimi-china": "kimi-cn", "fable": "openrouter", "deepseekflash": "deepseek"}.items():
            os.environ.pop("LANE_SYNC_TEST_LANES", None)
            self.assertEqual(ls.resolve_lane(name), lane)
        for cmd in (("accept", "nosuch", "x"), ("revert", "nosuch"), ("test", "nosuch")):
            r = self.run_cli(*cmd)
            self.assertEqual(r.returncode, 1, cmd)
            self.assertIn("unknown lane", r.stderr)
        self.assertFalse([n for n in os.listdir(self.tmp) if n.startswith("nosuch")])

    def test_1m_suffix_survives_an_accept(self):
        self.banner("k3[1m]", "b", "c")
        Fake.ids = ["org/old", "k4"]
        self.banner("k3[1m]", "b", "c")
        self.run_cli("test", "fake")
        self.run_cli("accept", "fake", "k4", "--replace", "k3[1m]")
        self.assertEqual(self.banner("k3[1m]", "b", "c").stdout.splitlines()[0], "k4[1m]")

    def test_picker_treats_a_1m_row_as_covering_the_bare_id(self):
        st = {"models": {"k3": {"verdict": "pass", "listed": True}}}
        out = ls.merged_picker('{"modelPicker":{"options":[{"model":"k3[1m]"}]}}', st, {})
        self.assertEqual(len(json.loads(out)["modelPicker"]["options"]), 1)

    def test_huge_catalogs_list_but_never_auto_test(self):
        env = {**self.env, "LANE_SYNC_TEST_LANES": json.dumps({"fake": {**self.lanes["fake"], "auto_test": False}})}
        self.banner(env=env)
        Fake.ids = ["org/old", "org/new"]
        err = self.banner(env=env).stderr
        self.assertIn("+ org/new", err)
        self.assertNotIn("testing", err)

    def test_empty_wallet_says_tests_are_paused(self):
        env = {**self.env, "LANE_SYNC_TEST_LANES": json.dumps({"fake": {**self.lanes["fake"], "control": "org/ctl"}})}
        Fake.plan = {"org/ctl": "429"}
        self.banner(env=env)
        self.run_cli("test", "fake", env=env)
        err = self.banner(env=env).stderr
        self.assertIn("paused", err)
        self.assertNotIn("testing", err)

    def test_a_short_list_does_not_mark_everything_gone(self):
        Fake.ids = [f"org/m{i}" for i in range(10)]
        self.banner()
        Fake.ids = ["org/m0"]
        self.assertNotIn("- org/m5", self.banner().stderr)

    def test_background_child_gets_no_secrets(self):
        os.environ["CLOUDFLARE_API_TOKEN"] = "x"
        os.environ["GH_TOKEN"] = "x"
        self.addCleanup(os.environ.pop, "CLOUDFLARE_API_TOKEN")
        self.addCleanup(os.environ.pop, "GH_TOKEN")
        env = ls.child_env()
        self.assertIn("PATH", env)
        self.assertNotIn("CLOUDFLARE_API_TOKEN", env)
        self.assertNotIn("GH_TOKEN", env)


if __name__ == "__main__":
    unittest.main(verbosity=1)
