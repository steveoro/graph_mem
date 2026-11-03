"""The lockdown gate with the fake CLI: PASS for an inert CLI, FAIL for each vector of an obedient one,
the gate record, the bridge honouring it, and setup errors. CANARY_DIR and the "real" home are temp dirs."""

import contextlib
import io
import json
import os
import unittest
import uuid
from unittest import mock

from support import FakeCliCase, agent_cli, write_private

import bridge
import lockdown

FIELDS = {"profile", "result", "cli_path", "cli_realpath", "cli_version", "wrapper_digest", "models", "prompt_forms",
          "trust_omit", "run_as", "warnings", "passed_on"}


class LockdownCase(FakeCliCase):
    def setUp(self):
        super().setUp()
        self.canary_dir = os.path.join(self.tmp, "canary")
        self.home = os.path.join(self.tmp, "home")
        os.mkdir(self.canary_dir, 0o700)
        os.mkdir(self.home, 0o700)
        patcher = mock.patch.object(agent_cli, "real_home", return_value=self.home)
        patcher.start()
        self.addCleanup(patcher.stop)

    def gate(self, profile="claude", sidecar=None, models=("fake-model",)):
        if sidecar is not None:
            self.install(profile if isinstance(profile, str) else profile.name, sidecar=sidecar)
        if isinstance(profile, str):
            profile = agent_cli.load_profile(profile)
        out = io.StringIO()
        result = lockdown.run_gate(profile, list(models), canary_dir=self.canary_dir, out=out)
        return result, out.getvalue()

    def record(self, name="claude"):
        path = os.path.join(self.state, "gates", name + ".json")
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)


class PassTest(LockdownCase):
    def test_an_inert_cli_passes_and_the_record_has_every_field(self):
        result, report = self.gate()
        self.assertEqual(result, "PASS")
        record = self.record()
        self.assertEqual(set(record), FIELDS)
        self.assertEqual((record["result"], record["models"], record["prompt_forms"], record["trust_omit"], record["warnings"]),
                         ("PASS", ["fake-model"], ["stdin"], False, []))
        self.assertEqual(record["cli_realpath"], os.path.join(self.bin, "claude"))
        self.assertEqual(record["wrapper_digest"], agent_cli.wrapper_digest(agent_cli.load_profile("claude")))
        self.assertEqual(report.count("\nok  ") + report.startswith("ok  "), len(lockdown.VECTORS))
        self.assertNotIn("GMCANARY-", report)
        self.assertEqual(os.listdir(self.canary_dir), [])

    def test_devin_runs_both_prompt_forms_with_and_without_trust(self):
        self.assertEqual(self.gate("devin")[0], "PASS")
        record = self.record("devin")
        self.assertEqual((record["prompt_forms"], record["trust_omit"]), (["arg", "file"], True))

    def test_a_cli_that_refuses_without_trust_counts_as_not_loaded(self):
        self.assertEqual(self.gate("devin", sidecar={"refuse_without_trust": True})[0], "PASS")

    def test_the_command_line_and_the_default_models(self):
        with mock.patch.dict(os.environ, {"CANARY_DIR": self.canary_dir}), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(lockdown.main(["--profile", "claude", "--models", "fake-model"]), 0)
            self.assertEqual(lockdown.main(["--profile", "claude"]), 0)  # the models of the existing record
        self.assertEqual(self.record()["models"], ["fake-model"])

    def test_with_a_real_home_user_level_configs_are_warnings(self):
        write_private(os.path.join(self.home, "AGENTS.md"), "synthetic")
        env = dict(agent_cli.load_profile("claude")["env"], home="real")
        result, report = self.gate(self.variant("claude", env=env))
        self.assertEqual(result, "PASS")
        self.assertEqual(self.record()["warnings"], ["~/AGENTS.md exists and the CLI runs with your real HOME"])
        self.assertIn("WARN  ~/AGENTS.md", report)


class FailTest(LockdownCase):
    def test_each_vector_of_an_obedient_cli_fails(self):
        cases = {"read": "canary value in the output", "grep": "canary value in the output", "touch": "marker created",
                 "fetch": "listener fetched", "mcp": "marker created (mcp)"}
        for vector, reason in cases.items():
            with self.subTest(vector=vector):
                result, report = self.gate(sidecar={"obey": [vector]})
                self.assertEqual(result, "FAIL")
                self.assertIn(reason, report)
                self.assertNotIn("GMCANARY-", report)
                self.assertEqual((self.record()["result"], self.record()["passed_on"]), ("FAIL", None))
        self.assertEqual(os.listdir(self.canary_dir), [])

    def test_a_decoy_the_cli_loads_fails(self):
        result, report = self.gate("devin", sidecar={"load_decoys": True})
        self.assertEqual(result, "FAIL")
        self.assertIn("decoy instructions loaded", report)

    def test_the_bridge_refuses_a_failed_gate_and_a_new_pass_clears_tripped(self):
        self.gate(sidecar={"obey": ["touch"]})
        server = bridge.Bridge("t" * 32, self.state, {"claude": agent_cli.load_profile("claude")}, log=io.StringIO())
        request = {"profile": "claude", "model": "fake-model", "prompt": "Hi", "timeout_s": 30, "task": "judge",
                   "run_id": str(uuid.uuid4())}
        self.assertEqual(server.complete(request)[0], "gate_failed")
        server.trip("claude", request["run_id"])
        self.assertEqual(self.gate(sidecar={})[0], "PASS")
        self.assertFalse(server.tripped("claude"))
        self.assertEqual(server.complete(request)[0], "ok")


class SetupErrorTest(LockdownCase):
    def test_no_models_no_cli_or_a_cli_that_cannot_answer(self):
        with self.assertRaises(lockdown.SetupError):
            self.gate(models=())
        os.remove(os.path.join(self.state, "claude.token"))
        with self.assertRaises(lockdown.SetupError):
            self.gate()
        os.environ[agent_cli.override_variable("devin")] = os.path.join(self.bin, "gone")
        with self.assertRaises(lockdown.SetupError):
            self.gate("devin")
        with mock.patch.dict(os.environ, {"CANARY_DIR": self.canary_dir}), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(lockdown.main(["--profile", "devin", "--models", "fake-model"]), 2)
        self.assertFalse(os.path.exists(os.path.join(self.state, "gates", "devin.json")))
        self.assertEqual(os.listdir(self.canary_dir), [])


if __name__ == "__main__":
    unittest.main()
