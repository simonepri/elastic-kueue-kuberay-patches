"""Test controller RBAC setup with granted, stale, denied and failed inputs."""

import json
import os
import subprocess
import tempfile
import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SETUP = ROOT / "build/kueue/install-rbac.sh"
FAKE_KUBECTL = r"""#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
root = pathlib.Path.cwd()
with (root / "calls.jsonl").open("a") as stream:
    stream.write(json.dumps(args) + "\n")
if args[0] == "kustomize":
    assert args == ["kustomize", "third_party/kueue/config/default"]
    print((root / "rendered.json").read_text())
    if os.environ.get("FAIL_SOURCE"):
        sys.exit(7)
elif args[0] == "create":
    assert "--dry-run=client" in args
    assert args[args.index("-f") + 1] == "-"
    for item in json.load(sys.stdin)["items"]:
        print(json.dumps(item))
elif args[0] == "apply":
    data = json.load(sys.stdin)
    if os.environ.get("FAIL_APPLY"):
        sys.exit(9)
    assert data["metadata"]["name"] == "kueue-manager-role"
    (root / "applied.json").write_text(json.dumps(data))
elif args[:2] == ["auth", "can-i"]:
    assert args[2:] == ["list", "daemonsets.apps", "--all-namespaces",
        "--as=system:serviceaccount:kueue-system:kueue-controller-manager"]
    role = json.loads((root / "applied.json").read_text())
    allowed = any("apps" in rule["apiGroups"] and "daemonsets" in rule["resources"]
        and "list" in rule["verbs"] for rule in role["rules"])
    sys.exit(0 if allowed and not os.environ.get("DENY_AUTH") else 1)
else:
    raise AssertionError(args)
"""


class SetupRbacTest(unittest.TestCase):
    def execute(self, *, daemonsets=True, failure=None, role_count=1):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rules = [
                {"apiGroups": [""], "resources": ["pods"], "verbs": ["list"]},
                {
                    "apiGroups": ["admissionregistration.k8s.io"],
                    "resources": ["mutatingwebhookconfigurations"],
                    "resourceNames": ["kueue-mutating-webhook-configuration"],
                    "verbs": ["get", "update"],
                },
                {
                    "apiGroups": ["apiextensions.k8s.io"],
                    "resources": ["customresourcedefinitions"],
                    "resourceNames": ["clusterqueues.kueue.x-k8s.io"],
                    "verbs": ["get", "update"],
                },
            ]
            if daemonsets:
                rules.append(
                    {
                        "apiGroups": ["apps"],
                        "resources": ["daemonsets"],
                        "verbs": ["get", "list"],
                    }
                )
            role = {
                "apiVersion": "rbac.authorization.k8s.io/v1",
                "kind": "ClusterRole",
                "metadata": {"name": "kueue-manager-role"},
                "rules": rules,
            }
            rendered = {
                "apiVersion": "v1",
                "kind": "List",
                "items": [role] * role_count
                + [
                    {
                        "apiVersion": "v1",
                        "kind": "ServiceAccount",
                        "metadata": {"name": "kueue-controller-manager"},
                    }
                ],
            }
            (root / "rendered.json").write_text(json.dumps(rendered))
            binary = root / "kubectl"
            binary.write_text(FAKE_KUBECTL)
            binary.chmod(0o755)
            env = {**os.environ, "PATH": f"{root}:{os.environ['PATH']}"}
            if failure:
                env[failure] = "1"
            result = subprocess.run(
                ["bash", str(SETUP)], cwd=root, env=env, text=True, capture_output=True
            )
            calls = [
                json.loads(line)
                for line in (root / "calls.jsonl").read_text().splitlines()
            ]
            applied = (
                json.loads((root / "applied.json").read_text())
                if (root / "applied.json").exists()
                else None
            )
            return result, calls, applied, rules

    def test_install_preserves_generated_permissions(self):
        result, calls, applied, rules = self.execute()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(applied["rules"], rules)
        self.assertEqual(calls[-1][:2], ["auth", "can-i"])

    def test_stale_generated_role_fails_before_scenarios(self):
        result, _, _, _ = self.execute(daemonsets=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot list DaemonSets", result.stderr)

    def test_missing_or_duplicate_rendered_role_is_not_installed(self):
        for count in [0, 2]:
            with self.subTest(count=count):
                result, _, applied, _ = self.execute(role_count=count)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(applied)
                self.assertIn(
                    "expected exactly one rendered Kueue manager role", result.stderr
                )

    def test_actual_permission_denial_fails_before_scenarios(self):
        result, _, _, _ = self.execute(failure="DENY_AUTH")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot list DaemonSets", result.stderr)

    def test_source_and_apply_failures_stop_before_access_check(self):
        for failure in ["FAIL_SOURCE", "FAIL_APPLY"]:
            with self.subTest(failure=failure):
                result, calls, _, _ = self.execute(failure=failure)
                self.assertEqual(
                    result.returncode, 7 if failure == "FAIL_SOURCE" else 9
                )
                self.assertFalse(any(call[:2] == ["auth", "can-i"] for call in calls))

    def test_cluster_setup_installs_rbac_before_controller_rollout(self):
        task_run = tomllib.loads((ROOT / "mise.toml").read_text())["tasks"]["cluster:up"]["run"]
        entries = task_run if isinstance(task_run, list) else [task_run]
        script_parts = []
        for entry in entries:
            entry_str = str(entry).strip()
            script_path = ROOT / entry_str
            if script_path.is_file():
                script_parts.append(script_path.read_text())
            else:
                self.assertFalse(entry_str.endswith(".sh"), f"cluster:up script {script_path} does not exist")
                script_parts.append(entry_str)
        script = "\n".join(script_parts)
        call = "bash build/kueue/install-rbac.sh"
        self.assertEqual(script.count(call), 1)
        self.assertLess(
            script.index(call),
            script.index("kubectl rollout status deployment/kueue-controller-manager"),
        )


if __name__ == "__main__":
    unittest.main()
