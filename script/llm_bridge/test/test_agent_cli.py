"""The wrapper with the fake CLI: every failure class, timeouts and the process group, the output cap,
the envelope rules, tool use by each signal, and the ``run`` and ``check`` subcommands."""

import contextlib
import io
import json
import os
import time
import unittest
from unittest import mock

from support import FakeCliCase, agent_cli

# One synthetic failure text per pattern class, for both profiles.
SAMPLES = {
    "prompt_too_long": "Prompt is too long",
    "cli_quota": "You have reached your usage limit",
    "cli_rate_limited": "Error: rate limit exceeded, please retry",
    "cli_auth": "Not logged in",
    "cli_model_unavailable": "The model zq7-model was not found",
    "cli_payment_required": "Payment required for this plan",
    "cli_config": "error: unknown option '--zq7'",
    "cli_sandbox": "sandbox could not be started",
    "cli_truncated": "Output was truncated at max_tokens",
    "cli_turn_limit": "Reached the maximum turns for this run",
}


def alive(pid):
    try:
        with open("/proc/%d/stat" % pid, encoding="utf-8") as handle:
            return handle.read().split(")")[-1].split()[0] != "Z"
    except OSError:
        return False


class ClassesTest(FakeCliCase):
    def test_ok_for_both_profiles_with_ansi_and_control_characters_stripped(self):
        for name in ("claude", "devin"):
            result, _ = self.run_fake(name, "@fake answer=\x1b[31mSynth\x1b[0mWidget\tok\x07\n")
            self.assertEqual(result["failure_class"], None)
            self.assertEqual(result["text"].strip(), "SynthWidget\tok")
            self.assertEqual((result["ok"], result["model_used"]), (True, "fake-model"))
            self.assertIsInstance(result["latency_ms"], float)

    def test_each_pattern_class_for_both_profiles(self):
        for cls, text in SAMPLES.items():
            with self.subTest(cls=cls):
                claude, _ = self.run_fake("claude", "@fake is_error\n@fake answer=%s\n" % text)
                self.assertEqual(claude["failure_class"], cls)
                self.assertIsNone(claude["text"])
                devin, _ = self.run_fake("devin", "@fake exit=1\n@fake stderr=%s\n" % text)
                self.assertEqual(devin["failure_class"], cls)

    def test_the_claude_subtype_classifies_too(self):
        result, _ = self.run_fake("claude", "@fake is_error\n@fake subtype=error_max_turns\n@fake answer=\n")
        self.assertEqual(result["failure_class"], "cli_turn_limit")

    def test_cli_missing(self):
        os.environ[agent_cli.override_variable("devin")] = os.path.join(self.bin, "nope")
        self.assertEqual(self.run_fake("devin", "Hi")[0]["failure_class"], "cli_missing")
        os.chmod(os.path.join(self.bin, "claude"), 0o644)
        self.assertEqual(self.run_fake("claude", "Hi")[0]["failure_class"], "cli_missing")

    def test_prompt_too_long_by_size_runs_nothing(self):
        profile = self.variant("claude", prompt=[{"mode": "stdin", "max_bytes": 16}])
        result, raw = self.run_fake(profile, "@fake hook=Bash\n" + "x" * 16)
        self.assertEqual(result["failure_class"], "prompt_too_long")
        self.assertEqual(raw["stdout"], "")

    def test_cli_error_and_exit_codes(self):
        self.assertEqual(self.run_fake("devin", "@fake exit=3\n@fake stderr=boom\n")[0]["failure_class"], "cli_error")
        profile = self.variant("devin", exit_codes={"3": "cli_quota"})
        self.assertEqual(self.run_fake(profile, "@fake exit=3\n")[0]["failure_class"], "cli_quota")

    def test_cli_bad_output(self):
        cases = {"claude": ["@fake raw=not json\n", "@fake no_result\n", '@fake raw={"result": 42}\n', "@fake answer=\n",
                            "@fake answer=   \n", "@fake raw=%s\n" % ("[" * 100000)],
                 "devin": ["@fake answer=\n"]}
        for name, prompts in cases.items():
            for prompt in prompts:
                with self.subTest(name=name, prompt=prompt):
                    self.assertEqual(self.run_fake(name, prompt)[0]["failure_class"], "cli_bad_output")

    def test_the_stdout_cap(self):
        over, _ = self.run_fake("devin", "@fake flood=%d\n@fake sleep=30\n" % (agent_cli.STDOUT_CAP + 1), timeout=20)
        self.assertEqual(over["failure_class"], "cli_bad_output")
        under, _ = self.run_fake("devin", "@fake flood=%d\n" % (agent_cli.STDOUT_CAP - 4096))
        self.assertEqual(under["failure_class"], None)

    def test_a_timeout_kills_the_whole_process_group(self):
        pid_file = os.path.join(self.tmp, "child.pid")
        started = time.monotonic()
        with mock.patch.object(agent_cli, "TERM_GRACE_S", 0.5):
            result, _ = self.run_fake("devin", "@fake spawn_child=%s\n@fake ignore_term\n@fake sleep=30\n" % pid_file, timeout=1)
        self.assertEqual(result["failure_class"], "cli_timeout")
        self.assertLess(time.monotonic() - started, 10)
        with open(pid_file, encoding="utf-8") as handle:
            child = int(handle.read())
        deadline = time.monotonic() + 3
        while alive(child) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertFalse(alive(child))

    def test_a_child_left_behind_by_a_finished_run_is_killed_too(self):
        pid_file = os.path.join(self.tmp, "child.pid")
        self.assertTrue(self.run_fake("devin", "@fake spawn_child=%s\n" % pid_file)[0]["ok"])
        with open(pid_file, encoding="utf-8") as handle:
            child = int(handle.read())
        deadline = time.monotonic() + 3
        while alive(child) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertFalse(alive(child))


class ToolUseTest(FakeCliCase):
    def test_a_hook_log_line_for_this_run_is_tool_use_and_the_hook_denies(self):
        result, raw = self.run_fake("devin", "@fake hook=Bash\n@fake answer=Fine.\n", run_id="11111111-2222-4333-8444-555555555555")
        self.assertEqual(result["failure_class"], "cli_tool_use")
        self.assertIsNone(result["text"])
        self.assertEqual(len(raw["hook_lines"]), 1)
        self.assertEqual(raw["hook_lines"][0].split("\t")[1:], ["11111111-2222-4333-8444-555555555555", "Bash"])
        self.assertEqual(os.stat(os.path.join(self.state, "hook.log")).st_mode & 0o077, 0)

    def test_another_runs_hook_line_is_not_this_runs(self):
        with open(os.path.join(self.state, "hook.log"), "a", encoding="utf-8") as log:
            log.write("t\tother-run\tBash\n")
        self.assertTrue(self.run_fake("devin", "Hi")[0]["ok"])

    def test_more_turns_than_allowed(self):
        self.assertEqual(self.run_fake("claude", "@fake turns=2\n")[0]["failure_class"], "cli_tool_use")
        self.assertTrue(self.run_fake("claude", "@fake turns=1\n")[0]["ok"])

    def test_the_transcript_tool_step_garbage_and_absence(self):
        for transcript in ("tool", "garbage", "none", "deep"):
            with self.subTest(transcript=transcript):
                result, _ = self.run_fake("devin", "@fake transcript=%s\n" % transcript)
                self.assertEqual(result["failure_class"], "cli_tool_use")
        failed, _ = self.run_fake("devin", "@fake transcript=none\n@fake exit=1\n@fake stderr=Not logged in\n")
        self.assertEqual(failed["failure_class"], "cli_auth")

    def test_the_stdout_pattern(self):
        trace = dict(agent_cli.load_profile("devin")["tool_trace"], stdout_pattern=r"\[tool: ")
        profile = self.variant("devin", tool_trace=trace)
        self.assertEqual(self.run_fake(profile, "@fake answer=[tool: exec]\n")[0]["failure_class"], "cli_tool_use")

    def test_tool_use_wins_over_any_answer_or_failure(self):
        self.assertEqual(self.run_fake("claude", "@fake hook=Read\n@fake is_error\n@fake answer=Not logged in\n")[0]["failure_class"],
                         "cli_tool_use")


class CommandLineTest(FakeCliCase):
    def test_run_prints_the_result_json_and_check_reports_the_cli(self):
        prompt = os.path.join(self.tmp, "prompt.txt")
        with open(prompt, "w", encoding="utf-8") as handle:
            handle.write("@fake answer=Gadget Project ok\n")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = agent_cli.main(["run", "--profile", "devin", prompt, "fake-model", "20"])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out.getvalue())["text"].strip(), "Gadget Project ok")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(agent_cli.main(["check", "--profile", "claude"]), 0)
        report = json.loads(out.getvalue())
        self.assertEqual((report["cli_ok"], report["cli_version"]), (True, "0.0.0-fake (Fake CLI)"))
        self.assertEqual(report["cli_realpath"], os.path.join(self.bin, "claude"))
        self.assertRegex(report["wrapper_digest"], r"\A[0-9a-f]{64}\Z")

    def test_the_version_cache_sees_a_swapped_binary(self):
        profile = agent_cli.load_profile("claude")
        found = agent_cli.resolve_cli(profile)
        self.assertEqual(agent_cli.cli_version(profile, found), "0.0.0-fake (Fake CLI)")
        self.install("claude", version="0.0.1-fake")
        self.assertEqual(agent_cli.cli_version(profile, agent_cli.resolve_cli(profile)), "0.0.1-fake (Fake CLI)")

    def test_an_unknown_profile_is_a_setup_error(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(agent_cli.main(["check", "--profile", "cursor"]), 2)


if __name__ == "__main__":
    unittest.main()
