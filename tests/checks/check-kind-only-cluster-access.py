#!/usr/bin/env python3
"""Checks that lab setup and e2e tests can only reach this repository's kind cluster: the guard rejects any other
context or server, and every cluster command in the setup script runs after it."""

import os
import re
import subprocess
import tempfile
import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUARD = ROOT / "build/cluster/require-kind-context.sh"
SETUP = ROOT / "build/cluster/up.sh"
GUARD_CALL = "bash build/cluster/require-kind-context.sh"

FAKE_KUBECTL = """#!/usr/bin/env bash
case "$*" in
  "config current-context") [ -n "$FAKE_CONTEXT" ] && echo "$FAKE_CONTEXT" || exit 1 ;;
  "config view --minify -o jsonpath={.clusters[0].cluster.server}") printf %s "$FAKE_SERVER" ;;
  *) echo "unexpected kubectl $*" >&2; exit 2 ;;
esac
"""


class GuardTest(unittest.TestCase):
    def run_guard(self, context, server, kubeconfig="lab/kubeconfig"):
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "kubectl"
            binary.write_text(FAKE_KUBECTL)
            binary.chmod(0o755)
            env = {
                **os.environ,
                "PATH": f"{tmp}:{os.environ['PATH']}",
                "HOME": tmp,
                "CLUSTER_NAME": "lab",
                "FAKE_CONTEXT": context,
                "FAKE_SERVER": server,
            }
            env.pop("KUBECONFIG", None)
            if kubeconfig is not None:
                env["KUBECONFIG"] = kubeconfig.replace("~", tmp)
            return subprocess.run(["bash", str(GUARD)], env=env, text=True, capture_output=True)

    def test_accepts_the_local_kind_cluster(self):
        for server in ["https://127.0.0.1:41234", "https://localhost:6443", "https://[::1]:6443"]:
            with self.subTest(server=server):
                result = self.run_guard("kind-lab", server)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_another_cluster(self):
        cases = {
            "foreign context": ("production", "https://127.0.0.1:41234", "lab/kubeconfig"),
            "kind name on a remote server": ("kind-lab", "https://example.com:443", "lab/kubeconfig"),
            "no context": ("", "https://127.0.0.1:41234", "lab/kubeconfig"),
            "no kubeconfig": ("kind-lab", "https://127.0.0.1:41234", None),
            "default kubeconfig": ("kind-lab", "https://127.0.0.1:41234", "~/.kube/config"),
            "several kubeconfigs": ("kind-lab", "https://127.0.0.1:41234", "a:b"),
        }
        for name, (context, server, kubeconfig) in cases.items():
            with self.subTest(name):
                result = self.run_guard(context, server, kubeconfig)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("refusing to touch a cluster", result.stderr)


class WiringTest(unittest.TestCase):
    def test_cluster_scripts_parse(self):
        for script in [SETUP, GUARD]:
            with self.subTest(script=script.name):
                result = subprocess.run(["bash", "-n", str(script)], text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_setup_touches_the_cluster_only_after_the_guard(self):
        lines = SETUP.read_text().splitlines()
        guard_at = next(i for i, line in enumerate(lines) if line.strip() == GUARD_CALL)
        cluster_command = re.compile(r"(^|[|;&(]\s*|\$\()\s*(kubectl|helm\s+(install|upgrade|uninstall))\b")
        for i, line in enumerate(lines):
            if line.lstrip().startswith("#"):
                continue
            if cluster_command.search(line):
                self.assertGreater(i, guard_at, f"up.sh line {i + 1} reaches a cluster before the guard: {line.strip()}")

    def test_tasks_use_only_the_repository_kubeconfig(self):
        config = tomllib.loads((ROOT / "mise.toml").read_text())
        self.assertEqual(config["env"]["KUBECONFIG"], "{{config_root}}/.local/kind/kubeconfig")
        e2e = config["tasks"]["test:e2e"]["run"]
        self.assertEqual(e2e[0], GUARD_CALL)
        self.assertIn("--kubeconfig", config["tasks"]["cluster:down"]["run"])


if __name__ == "__main__":
    unittest.main()
