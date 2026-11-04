"""Shared test setup for script/llm_bridge: a temp state dir, the fake CLI installed under each profile's
name, and a random 0600 claude token. Nothing touches the real home, a real CLI or the network."""

import json
import os
import secrets
import shutil
import sys
import tempfile
import unittest
import uuid
from unittest import mock

TEST_DIR = os.path.dirname(os.path.realpath(__file__))
BRIDGE_DIR = os.path.dirname(TEST_DIR)
FAKE = os.path.join(TEST_DIR, "fake_cli.py")
if BRIDGE_DIR not in sys.path:
    sys.path.insert(0, BRIDGE_DIR)

import agent_cli  # noqa: E402


def write_private(path, text, mode=0o600):
    """Write ``text`` to ``path`` with ``mode`` (default 0600)."""
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.chmod(path, mode)


class FakeCliCase(unittest.TestCase):
    """Each test gets its own state dir, fake CLIs for ``claude`` and ``devin`` and a fresh version cache."""

    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="llm-bridge-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.state = os.path.join(self.tmp, "state")
        self.bin = os.path.join(self.tmp, "bin")
        self.runtime = os.path.join(self.tmp, "runtime")
        for folder in (self.state, self.bin, self.runtime):
            os.mkdir(folder, 0o700)
        self.runs = os.path.join(self.runtime, "agent-cli")
        patcher = mock.patch.dict(os.environ, {"AGENT_CLI_STATE": self.state, "XDG_RUNTIME_DIR": self.runtime})
        patcher.start()
        self.addCleanup(patcher.stop)
        for name in ("claude", "devin"):
            self.install(name)
        write_private(os.path.join(self.state, "claude.token"), "fake-" + secrets.token_urlsafe(24))
        agent_cli._VERSIONS.clear()

    def install(self, name, version="0.0.0-fake", sidecar=None):
        """Install the fake CLI as ``bin/<name>`` (a new inode each time) and point the profile at it."""
        with open(FAKE, encoding="utf-8") as handle:
            source = handle.read().split("\n", 1)[1].replace('VERSION = "0.0.0-fake"', 'VERSION = "%s"' % version)
        path = os.path.join(self.bin, name)
        write_private(path + ".new", "#!%s\n%s" % (sys.executable, source), 0o755)
        os.replace(path + ".new", path)
        os.environ[agent_cli.override_variable(name)] = path
        if sidecar is not None:
            write_private(path + ".json", json.dumps(sidecar))
        return path

    def run_fake(self, profile, prompt, model="fake-model", timeout=20, **options):
        """Run ``agent_cli.run_cli`` against the fake; ``profile`` is a name or a Profile."""
        if isinstance(profile, str):
            profile = agent_cli.load_profile(profile)
        run_id = options.pop("run_id", str(uuid.uuid4()))
        return agent_cli.run_cli(profile, prompt, model, timeout, run_id, **options)

    def variant(self, name, **changes):
        """A copy of a shipped profile with top-level keys replaced (written next to the state dir)."""
        with open(os.path.join(BRIDGE_DIR, "profiles", name + ".json"), encoding="utf-8") as handle:
            data = json.load(handle)
        data.update(changes)
        path = os.path.join(self.tmp, name + "-variant.json")
        write_private(path, json.dumps(data))
        return agent_cli.Profile(data, path)
