"""The #153 follow-ups (agent-CLI PR4, step H): the parent rule for the state and runs dirs, the
``tool_trace.name_map`` key, a ``hook.log`` that moves mid-run, ``hook.log`` rotation, and the synthetic
envelope fixtures. Temp dirs, the fake CLI and synthetic data only."""

import collections
import json
import os
import threading
import unittest
from unittest import mock

from support import BRIDGE_DIR, FakeCliCase, agent_cli

import bridge
import tool_trace

FIXTURES = os.path.join(os.path.dirname(os.path.dirname(BRIDGE_DIR)), "spec", "fixtures", "llm_bridge", "envelopes")
Group = collections.namedtuple("Group", "gr_mem")
Account = collections.namedtuple("Account", "pw_uid pw_gid")


class ParentRuleTest(FakeCliCase):
    """``state_dir`` and ``runs_dir`` share one rule: parents writable only by the user, root or the user's
    own private group."""

    def setUp(self):
        super().setUp()
        self.home = os.path.join(self.tmp, "home")
        os.mkdir(self.home, 0o700)
        os.chown(self.home, -1, os.getgid())
        os.chmod(self.home, 0o775)
        self.private = os.path.join(self.home, "state")
        os.mkdir(self.private, 0o700)
        agent_cli._private_group.cache_clear()
        self.addCleanup(agent_cli._private_group.cache_clear)

    def accounts(self, members=(), others=()):
        """Patch the group and passwd databases: the user's group with ``members``, and ``others`` accounts sharing it."""
        me = Account(os.getuid(), os.getgid())
        group = mock.patch.object(agent_cli.grp, "getgrgid", return_value=Group(list(members)))
        users = mock.patch.object(agent_cli.pwd, "getpwall", return_value=[me] + [Account(uid, os.getgid()) for uid in others])
        for patcher in (group, users):
            patcher.start()
            self.addCleanup(patcher.stop)

    def state_dir(self):
        with mock.patch.dict(os.environ, {"AGENT_CLI_STATE": self.private}):
            return agent_cli.state_dir()

    def test_a_0775_home_with_a_private_group_passes(self):
        self.accounts()
        self.assertEqual(self.state_dir(), os.path.realpath(self.private))
        self.assertTrue(agent_cli.private_dir(self.private, parents=True))

    def test_a_0775_home_whose_group_has_another_member_or_account_is_refused(self):
        for members, others in ((["zq7-other"], ()), ((), (os.getuid() + 4242,))):
            with self.subTest(members=members, others=others):
                agent_cli._private_group.cache_clear()
                self.accounts(members, others)
                with self.assertRaises(agent_cli.UnsafeDir) as caught:
                    self.state_dir()
                self.assertIn(self.home, str(caught.exception))
                self.assertFalse(agent_cli.private_dir(self.private, parents=True))

    def test_another_group_or_an_other_writable_parent_is_refused(self):
        self.accounts()
        mine = os.getgid()
        with mock.patch.object(agent_cli.os, "getgid", return_value=mine + 4242):  # the dir's group isn't the user's
            self.assertFalse(agent_cli.private_group(mine))
        os.chmod(self.home, 0o777)
        with self.assertRaises(agent_cli.UnsafeDir):
            self.state_dir()
        os.chmod(self.home, 0o755)
        self.assertEqual(self.state_dir(), os.path.realpath(self.private))

    def test_the_runs_dir_follows_the_same_rule(self):
        self.accounts(["zq7-other"])
        os.chmod(self.runtime, 0o700)
        os.chmod(self.tmp, 0o770)
        os.chown(self.tmp, -1, os.getgid())
        self.addCleanup(os.chmod, self.tmp, 0o700)
        with self.assertRaises(agent_cli.UnsafeDir):
            agent_cli.runs_dir(self.state)
        agent_cli._private_group.cache_clear()
        self.accounts()
        self.assertEqual(agent_cli.runs_dir(self.state), self.runs)


class NameMapTest(FakeCliCase):
    """``tool_trace.name_map`` renames a transcript tool before it is matched to a refusal; it never excuses one."""

    def mapped(self, name_map):
        trace = dict(agent_cli.load_profile("devin")["tool_trace"], name_map=name_map)
        return self.variant("devin", tool_trace=trace)

    def outcome(self, profile, prompt):
        return self.run_fake(profile, prompt)[0]["failure_class"]

    def test_devin_ships_an_empty_map(self):
        self.assertEqual(agent_cli.load_profile("devin")["tool_trace"]["name_map"], {})
        self.assertNotIn("name_map", agent_cli.load_profile("claude")["tool_trace"])

    def test_a_renamed_tool_needs_the_map_and_its_own_refusal(self):
        renamed = self.mapped({"exec": "run_command"})
        self.assertEqual(self.outcome("devin", "@fake hook=run_command\n@fake transcript=tool\n"), "cli_tool_use")
        self.assertEqual(self.outcome(renamed, "@fake hook=run_command\n@fake transcript=tool\n"), "cli_tool_denied")
        self.assertEqual(self.outcome(renamed, "@fake hook=grep\n@fake transcript=tool\n"), "cli_tool_use")  # target never refused
        self.assertEqual(self.outcome(renamed, "@fake hook=run_command\n@fake transcript=tool2\n"), "cli_tool_use")  # two calls
        self.assertEqual(self.outcome(renamed, "@fake hook=run_command\n@fake transcript=unnamed\n"), "cli_tool_use")
        self.assertEqual(self.outcome(renamed, "@fake hook=exec\n@fake transcript=tool\n"), "cli_tool_use")  # exec now means run_command

    def test_the_map_is_validated_and_in_the_wrapper_digest(self):
        for bad in ({"Exec": "run"}, {"exec": "Run"}, {"exec": 1}, {"": "run"}, {"exec": "-x"}, []):
            with self.subTest(bad=bad), self.assertRaises(agent_cli.ProfileError):
                self.mapped(bad)
        self.assertNotEqual(agent_cli.wrapper_digest(self.mapped({})), agent_cli.wrapper_digest(self.mapped({"exec": "run_command"})))


class MovedLogTest(FakeCliCase):
    """A ``hook.log`` rotated, replaced, truncated or removed since the mark fails closed."""

    def setUp(self):
        super().setUp()
        self.log = os.path.join(self.state, "hook.log")
        with open(self.log, "w", encoding="utf-8") as handle:
            handle.write("t\trun-1\tBash\n")

    def test_lines_since_the_mark(self):
        mark = tool_trace.log_mark(self.log)
        with open(self.log, "a", encoding="utf-8") as handle:
            handle.write("t\trun-2\texec\n")
        self.assertEqual(tool_trace.hook_lines(self.state, mark, "run-2"), ["t\trun-2\texec"])
        self.assertEqual(tool_trace.hook_lines(self.state, mark, "run-1"), [])
        self.assertEqual(tool_trace.hook_lines(self.state, (None, 0), "run-1"), ["t\trun-1\tBash"])

    def test_a_moved_truncated_or_removed_log_is_none(self):
        mark = tool_trace.log_mark(self.log)
        os.replace(self.log, self.log + ".1")
        self.assertIsNone(tool_trace.hook_lines(self.state, mark, "run-1"))
        with open(self.log, "w", encoding="utf-8") as handle:
            handle.write("t\trun-1\tBash\n" * 3)
        self.assertIsNone(tool_trace.hook_lines(self.state, mark, "run-1"))
        mark = tool_trace.log_mark(self.log)
        with open(self.log, "w", encoding="utf-8"):
            pass
        self.assertIsNone(tool_trace.hook_lines(self.state, mark, "run-1"))
        os.remove(self.log)
        self.assertIsNone(tool_trace.hook_lines(self.state, mark, "run-1"))

    def test_none_is_tool_use_only_where_the_hook_is_wired(self):
        proc, envelope = {"exit": 0}, {"turns": None}
        devin, claude = agent_cli.load_profile("devin"), agent_cli.load_profile("claude")
        self.assertEqual(tool_trace.tool_use(devin, proc, envelope, None, "{}", ""), "used")
        self.assertIsNone(tool_trace.tool_use(claude, proc, envelope, None, None, ""))


class RotationTest(FakeCliCase):
    """``hook.log`` moves to ``hook.log.1`` past 1 MiB, only while every profile lock is free."""

    def setUp(self):
        super().setUp()
        self.bridge = bridge.Bridge("fake-" + "x" * 40, self.state, {name: agent_cli.load_profile(name) for name in ("claude", "devin")})
        self.log = os.path.join(self.state, "hook.log")

    def fill(self, size):
        with open(self.log, "wb") as handle:
            handle.write(b"t\tzq7\tBash\n" * (size // 11 + 1))
        os.chmod(self.log, 0o600)

    def test_rotates_one_generation_past_1_mib(self):
        self.fill(bridge.ROTATE_BYTES + 1)
        old = os.path.getsize(self.log)
        with open(self.log + ".1", "w", encoding="utf-8") as handle:
            handle.write("older generation\n")
        self.assertTrue(self.bridge.rotate_hook_log("devin"))
        self.assertFalse(os.path.exists(self.log))
        self.assertEqual(os.path.getsize(self.log + ".1"), old)
        self.assertEqual(os.stat(self.log + ".1").st_mode & 0o777, 0o600)
        self.assertFalse(self.bridge.locks["claude"].locked())

    def test_not_under_the_limit_nor_while_another_profile_runs(self):
        self.fill(bridge.ROTATE_BYTES - 64)
        self.assertFalse(self.bridge.rotate_hook_log("devin"))
        self.fill(bridge.ROTATE_BYTES + 1)
        held = threading.Lock()
        with mock.patch.dict(self.bridge.locks, {"claude": held}):
            held.acquire()
            try:
                self.assertFalse(self.bridge.rotate_hook_log("devin"))
            finally:
                held.release()
        self.assertTrue(os.path.exists(self.log))
        self.assertFalse(os.path.exists(self.log + ".1"))

    def test_a_request_rotates_before_its_run(self):
        self.fill(bridge.ROTATE_BYTES + 1)
        with mock.patch.object(self.bridge, "gate_check", return_value=("gate_missing", {"cli_version": None})):
            self.assertEqual(self.bridge.complete({"profile": "devin", "model": "fake-model"})[0], "gate_missing")
        self.assertTrue(os.path.exists(self.log + ".1"))
        self.assertFalse(self.bridge.locks["devin"].locked())


class EnvelopeFixtureTest(FakeCliCase):
    """The synthetic envelopes in spec/fixtures/llm_bridge/envelopes/ parse as each profile's output."""

    def test_the_claude_envelope_through_the_fake_cli(self):
        with open(os.path.join(FIXTURES, "claude.json"), encoding="utf-8") as handle:
            envelope = json.load(handle)
        self.assertEqual(envelope["_note"], "synthetic, replace with a sanitized capture")
        result, _ = self.run_fake("claude", "@fake raw=%s\n" % json.dumps(envelope))
        self.assertEqual((result["failure_class"], result["text"]), (None, envelope["result"]))

    def test_the_devin_text_is_the_answer_as_it_is(self):
        with open(os.path.join(FIXTURES, "devin.txt"), encoding="utf-8") as handle:
            text = handle.read()
        self.assertIn("synthetic", text.lower())
        self.assertEqual(agent_cli.unwrap(agent_cli.load_profile("devin"), text)["text"], text)


if __name__ == "__main__":
    unittest.main()
