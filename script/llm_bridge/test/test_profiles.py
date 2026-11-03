"""Profiles: loading and strict validation, argv per profile and prompt mode, the environment and the run dir."""

import copy
import json
import os
import tempfile
import unittest
from unittest import mock

from support import BRIDGE_DIR, FakeCliCase, agent_cli, write_private


def shipped(name):
    with open(os.path.join(BRIDGE_DIR, "profiles", name + ".json"), encoding="utf-8") as handle:
        return json.load(handle)


class ProfileLoadingTest(unittest.TestCase):
    def test_both_shipped_profiles_load(self):
        self.assertEqual(agent_cli.shipped_profiles(), ["claude", "devin"])
        for name in ("claude", "devin"):
            self.assertEqual(agent_cli.load_profile(name).name, name)

    def test_unknown_or_unsafe_names_are_refused(self):
        for name in ("cursor", "../claude", "Claude", "", None):
            with self.assertRaises(agent_cli.ProfileError):
                agent_cli.load_profile(name)

    def test_a_misspelled_key_fails_at_every_level(self):
        breakers = [
            lambda d: d.update(lockdown_arg=d.pop("lockdown_args")),
            lambda d: d["tool_trace"].update(hook_logs=d["tool_trace"].pop("hook_log")),
            lambda d: d["env"].update(secret=d["env"].pop("secret_env")),
            lambda d: d["output"].update(text=d["output"].pop("text_path")),
            lambda d: d["prompt"][0].update(max_byte=1),
            lambda d: d["config_files"][0].update(contents="x"),
        ]
        for breaker in breakers:
            data = copy.deepcopy(shipped("claude"))
            breaker(data)
            with self.subTest(breaker=breaker), self.assertRaises(agent_cli.ProfileError):
                agent_cli.Profile(data, "claude.json")

    def test_wrong_types_missing_keys_bad_regexes_and_unsafe_values_fail(self):
        breakers = [
            lambda d: d.update(lockdown_args="--tools ''"),
            lambda d: d.update(tools_fully_disabled="yes"),
            lambda d: d.pop("trust_args"),
            lambda d: d["failure_patterns"].update(cli_auth="(unclosed"),
            lambda d: d["failure_patterns"].update(cli_unknown="x"),
            lambda d: d.update(model_pattern="[a-"),
            lambda d: d.update(model_flag="model"),
            lambda d: d["prompt"].__setitem__(0, {"mode": "stdin"}),
            lambda d: d["prompt"].__setitem__(0, {"mode": "pipe", "max_bytes": 1}),
            lambda d: d["config_files"][0].update(path="/etc/x.json"),
            lambda d: d["config_files"][0].update(path="{run}/../x.json"),
            lambda d: d["env"].update(home="mine"),
            lambda d: d["env"].update(**{"pass": ["PATH"]}),
            lambda d: d["env"]["secret_env"].update(HOME="{state}/x"),
            lambda d: d["env"]["set"].update(CLAUDE_CODE_OAUTH_TOKEN="x"),
            lambda d: d["env"]["set"].update(ZQ7_FLAG=1),
            lambda d: d["env"].pop("set"),
            lambda d: d["exit_codes"].update(three="cli_error"),
            lambda d: d["tool_trace"].update(max_turns=True),
            lambda d: d["output"].update(format="yaml"),
        ]
        for breaker in breakers:
            data = copy.deepcopy(shipped("claude"))
            breaker(data)
            with self.subTest(breaker=breaker), self.assertRaises(agent_cli.ProfileError):
                agent_cli.Profile(data, "claude.json")

    def test_a_hook_log_profile_must_wire_the_hook(self):
        data = shipped("devin")
        data["config_files"] = []
        with self.assertRaises(agent_cli.ProfileError):
            agent_cli.Profile(data, "devin.json")


class ArgvTest(unittest.TestCase):
    ctx = {"run": "/tmp/run", "home": "/tmp/run/home", "hook": "/x/deny-hook.sh", "state": "/s", "prompt": "Hi"}

    def test_claude_argv_and_the_stdin_threshold(self):
        profile = agent_cli.load_profile("claude")
        mode = agent_cli.choose_mode(profile, 10_000_000)
        self.assertEqual(mode["mode"], "stdin")
        self.assertIsNone(agent_cli.choose_mode(profile, 10_000_001))
        self.assertEqual(agent_cli.build_argv(profile, "/bin/claude", "sonnet", mode, self.ctx), [
            "/bin/claude", "-p", "--output-format", "json", "--max-turns", "1", "--safe-mode", "--tools", "", "--disallowedTools", "mcp__*",
            "--strict-mcp-config", "--mcp-config", "/tmp/run/empty-mcp.json", "--model", "sonnet"])

    def test_devin_argv_for_arg_and_file_modes(self):
        profile = agent_cli.load_profile("devin")
        lockdown = ["--permission-mode", "normal", "--sandbox", "--config", "/tmp/run/config.json", "--export", "/tmp/run/transcript.atif"]
        arg = agent_cli.choose_mode(profile, 98_304)
        self.assertEqual(agent_cli.build_argv(profile, "/bin/devin", "m1", arg, self.ctx),
                         ["/bin/devin", "-p", "--respect-workspace-trust", "false", *lockdown, "--model", "m1", "--", "Hi"])
        file_mode = agent_cli.choose_mode(profile, 98_305)
        self.assertEqual(agent_cli.build_argv(profile, "/bin/devin", "m1", file_mode, self.ctx, omit_trust=True),
                         ["/bin/devin", "-p", *lockdown, "--model", "m1", "--prompt-file", "/tmp/run/prompt.txt"])

    def test_a_model_outside_the_pattern_is_refused_before_anything_runs(self):
        profile = agent_cli.load_profile("claude")
        for model in ("--dangerously-skip-permissions", "-x", "a b", "a/b", "", "x" * 65):
            with self.subTest(model=model), self.assertRaises(ValueError):
                agent_cli.run_cli(profile, "Hi", model, 5, "id")


class EnvironmentAndRunDirTest(FakeCliCase):
    def test_the_env_holds_only_the_names_the_wrapper_sets(self):
        planted = {"DATABASE_URL": "mysql2://u:p@db.example/x", "RAILS_MASTER_KEY": "k" * 32, "SSH_AUTH_SOCK": "/tmp/agent.sock"}
        with mock.patch.dict(os.environ, planted):
            for name, extra in (("claude", ["CLAUDE_CODE_DISABLE_AUTO_MEMORY", "CLAUDE_CODE_DISABLE_CLAUDE_MDS", "CLAUDE_CODE_OAUTH_TOKEN"]), ("devin", [])):
                result, _ = self.run_fake(name, "@fake echo_env\n")
                self.assertEqual(result["text"].strip().split(","), sorted(list(agent_cli.BUILT_ENV) + extra))

    def test_home_and_xdg_dirs_are_synthetic_except_devins_data_home(self):
        profile = agent_cli.load_profile("devin")
        ctx = {"run": "/r", "home": "/r/home", "hook": "h", "state": self.state}
        with mock.patch.dict(os.environ, {"XDG_DATA_HOME": os.path.join(self.tmp, "share")}):
            env = agent_cli.build_env(profile, ("/b/devin", "/b/devin"), ctx, "id")
        self.assertEqual((env["HOME"], env["XDG_CONFIG_HOME"], env["XDG_CACHE_HOME"]), ("/r/home", "/r/config", "/r/cache"))
        self.assertEqual(env["XDG_DATA_HOME"], os.path.join(self.tmp, "share"))
        self.assertEqual(env["PATH"], "/b:" + agent_cli.BASE_PATH)
        claude = agent_cli.build_env(agent_cli.load_profile("claude"), ("/b/claude", "/v/claude"), ctx, "id")
        self.assertEqual((claude["XDG_DATA_HOME"], claude["PATH"]), ("/r/data", "/b:/v:" + agent_cli.BASE_PATH))

    def test_a_secret_file_that_is_not_the_users_0600_file_refuses(self):
        token = os.path.join(self.state, "claude.token")
        os.chmod(token, 0o644)
        self.assertEqual(self.run_fake("claude", "Hi")[0]["failure_class"], "cli_auth")
        os.remove(token)
        self.assertEqual(self.run_fake("claude", "Hi")[0]["failure_class"], "cli_auth")
        os.symlink(os.path.join(self.tmp, "elsewhere"), token)
        write_private(os.path.join(self.tmp, "elsewhere"), "fake-token")
        self.assertEqual(self.run_fake("claude", "Hi")[0]["failure_class"], "cli_auth")

    def test_the_run_dir_is_0700_while_running_and_gone_afterwards(self):
        made = []
        real_mkdtemp = tempfile.mkdtemp

        def record(**kwargs):
            made.append(real_mkdtemp(**kwargs))
            return made[-1]

        with mock.patch.object(agent_cli.tempfile, "mkdtemp", side_effect=record):
            result, _ = self.run_fake("devin", "@fake echo_cwd_mode\n")
        self.assertEqual(result["text"].strip(), "0o700")
        self.assertFalse(os.path.exists(made[0]))

    def test_a_failed_run_dir_is_kept_only_when_asked(self):
        made = []
        real_mkdtemp = tempfile.mkdtemp
        with mock.patch.object(agent_cli.tempfile, "mkdtemp", side_effect=lambda **kw: made.append(real_mkdtemp(**kw)) or made[-1]), \
                mock.patch.dict(os.environ, {"AGENT_CLI_KEEP_FAILED": "1"}):
            self.run_fake("devin", "@fake exit=3\n")
            self.run_fake("devin", "Hi")
        self.addCleanup(lambda: [__import__("shutil").rmtree(path, True) for path in made])
        self.assertTrue(os.path.isdir(made[0]))
        self.assertEqual(os.stat(made[0]).st_mode & 0o777, 0o700)
        self.assertFalse(os.path.exists(made[1]))

    def test_config_files_land_in_the_run_dir_with_substitutions(self):
        result, _ = self.run_fake("claude", "@fake echo_argv\n")
        argv = json.loads(result["text"])
        mcp_config = argv[argv.index("--mcp-config") + 1]
        self.assertTrue(mcp_config.endswith("/empty-mcp.json"))
        self.assertNotIn(self.tmp, mcp_config)  # the run dir is a fresh temp dir, not under the state dir


if __name__ == "__main__":
    unittest.main()
