"""Verify bounded delayed-topology polling and cleanup against a fake API."""

import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCENARIO = ROOT / "tests/checks/fixtures/delayed-topology"
KUBECTL = r"""#!/usr/bin/env python3
import json, os, pathlib, sys

root = pathlib.Path(os.environ["FAKE_API"])
args = sys.argv[1:]
request_timeout = args.pop(0)
operation_timeout = next(
    (a.split("=", 1)[1] for a in args if a.startswith("--timeout=")), None
)
expected_timeout = (
    int(operation_timeout.removesuffix("s")) + 5 if operation_timeout else 5
)
assert request_timeout == f"--request-timeout={expected_timeout}s", args
with (root / "calls.jsonl").open("a") as stream:
    stream.write(json.dumps(args) + "\n")
if args[:1] == ["-n"]:
    args = args[2:]
verb = args[0]
kind = args[1] if len(args) > 1 else ""
attempt_label = "kueue.x-k8s.io/karpenter-attempt"
labels = {
    "kueue.x-k8s.io/workload": "gang",
    attempt_label: "attempt",
}
claims = [
    {
        "metadata": {
            "name": "claim" + str(i),
            "labels": labels,
            "annotations": {"kueue.x-k8s.io/karpenter-pods": "1"},
        },
        "spec": {"taints": []},
    }
    for i in range(3)
]
state_file = root / "registered.json"
registered = json.loads(state_file.read_text()) if state_file.exists() else []
ready = len(registered) == 3
if verb == "get" and kind == "nodeclaims" and os.environ.get("FAIL_REQUEST"):
    print("simulated API request failure", file=sys.stderr)
    sys.exit(7)
if verb == "get":
    if kind == "nodeclaims":
        print(json.dumps({"items": claims[: int(os.environ.get("CLAIM_COUNT", "3"))]}))
    elif kind == "nodeclaim":
        print(json.dumps(next(c for c in claims if c["metadata"]["name"] == args[2])))
    elif kind == "workload":
        assignment = {
            "flavors": {"cpu": "delayed-tas-karpenter"},
            "delayedTopologyRequest": "Ready" if ready else "Pending",
        }
        if ready:
            assignment["topologyAssignment"] = {
                "slices": [
                    {
                        "domainCount": 3,
                        "podCounts": {"universal": 1},
                        "valuesPerLevel": [
                            {
                                "individual": {
                                    "roots": ["tas-claim" + str(i) for i in range(3)]
                                }
                            }
                        ],
                    }
                ]
            }
        print(
            json.dumps(
                {
                    "status": {
                        "conditions": [
                            {"type": "QuotaReserved", "status": "True"},
                            {
                                "type": "Admitted",
                                "status": "True" if ready else "False",
                            },
                        ],
                        "admission": {"podSetAssignments": [assignment]},
                        "admissionChecks": [
                            {
                                "state": "Ready",
                                "podSetUpdates": [
                                    {
                                        "nodeSelector": {attempt_label: "attempt"},
                                        "tolerations": [
                                            {
                                                "key": "karpenter.sh/claimed-by",
                                                "value": "gang",
                                                "operator": "Equal",
                                            }
                                        ],
                                    }
                                ],
                            }
                        ],
                    }
                }
            )
        )
    elif kind == "workloads":
        print(
            json.dumps(
                {
                    "items": [
                        {
                            "metadata": {
                                "name": "gang",
                                "ownerReferences": [
                                    {"kind": "Job", "name": "delayed-tas-gang"}
                                ],
                            }
                        }
                    ]
                }
            )
        )
    elif kind == "nodes":
        if args[-1] == "name":
            print("\n".join("node/tas-claim" + str(i) for i in range(3)))
        else:
            print(
                json.dumps(
                    {
                        "items": [
                            {
                                "spec": {
                                    "taints": [
                                        {
                                            "key": "karpenter.sh/claimed-by",
                                            "value": "gang",
                                            "effect": "NoSchedule",
                                        }
                                    ]
                                }
                            }
                            for _ in range(3)
                        ]
                    }
                )
            )
    elif kind == "pods":
        print(
            json.dumps(
                {
                    "items": [
                        {
                            "metadata": {"name": "worker" + str(i)},
                            "spec": {
                                "nodeName": "tas-claim" + str(i),
                                "schedulingGates": [],
                            },
                        }
                        for i in range(3)
                    ]
                }
            )
        )
    elif kind == "pod":
        print(
            json.dumps(
                {
                    "spec": {},
                    "status": {
                        "conditions": [
                            {
                                "type": "PodScheduled",
                                "status": "False",
                                "message": "untolerated taint",
                            }
                        ]
                    },
                }
            )
        )
    elif kind == "workloads,pods":
        print("{}")
    else:
        raise AssertionError(args)
elif verb == "patch":
    if kind == "nodeclaim" and "Registered" in args[-1] and args[2] not in registered:
        registered.append(args[2])
        state_file.write_text(json.dumps(registered))
    print("{}")
elif verb == "create":
    json.load(sys.stdin)
    print("{}")
elif verb == "delete":
    if kind in {"node", "pod"} and "--wait=false" not in args:
        assert "--timeout=10s" in args, args
    if os.environ.get("FAIL_CLEANUP") and kind == "pod" and args[2] == "rogue":
        sys.exit(9)
elif verb == "wait":
    assert any(a.startswith("--timeout=") for a in args), args
else:
    raise AssertionError(args)
"""


class DelayedTopologyBoundsTest(unittest.TestCase):
    def execute(
        self, script, *, claims=3, cleanup_failure=False, request_failure=False
    ):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "kubectl"
            binary.write_text(KUBECTL)
            binary.chmod(0o755)
            env = {
                **os.environ,
                "PATH": f"{root}:{os.environ['PATH']}",
                "FAKE_API": str(root),
                "NS": "example",
                "CLAIM_COUNT": str(claims),
                "WAIT_TIMEOUT_SECONDS": "1",
                "KUBECTL_REQUEST_TIMEOUT_SECONDS": "5",
            }
            if cleanup_failure:
                env["FAIL_CLEANUP"] = "1"
            if request_failure:
                env["FAIL_REQUEST"] = "1"
            start = time.monotonic()
            result = subprocess.run(
                ["bash", str(SCENARIO / script)],
                cwd=SCENARIO,
                env=env,
                text=True,
                capture_output=True,
                timeout=30,
            )
            elapsed = time.monotonic() - start
            calls = [
                json.loads(line)
                for line in (root / "calls.jsonl").read_text().splitlines()
            ]
            return result, elapsed, calls

    def test_missing_claims_stop_and_cleanup_preserves_failure(self):
        result, elapsed, calls = self.execute(
            "register-and-assert.sh", claims=0, cleanup_failure=True
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertLess(elapsed, 4)
        self.assertIn("count 3; observed 0", result.stderr)
        self.assertTrue(any(call[:3] == ["delete", "node", "-l"] for call in calls))
        self.assertTrue(
            any("delayed-tas-gang" in call and "delete" in call for call in calls)
        )

    def test_api_request_failure_stops_before_registration(self):
        result, elapsed, calls = self.execute(
            "register-and-assert.sh", request_failure=True
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertLess(elapsed, 4)
        self.assertIn("simulated API request failure", result.stderr)
        self.assertNotIn("Timed out waiting", result.stderr)
        self.assertFalse(any(call[:2] == ["patch", "nodeclaim"] for call in calls))

    def test_obsolete_two_claim_shape_does_not_pass(self):
        result, elapsed, _ = self.execute("register-and-assert.sh", claims=2)
        self.assertNotEqual(result.returncode, 0)
        self.assertLess(elapsed, 4)
        self.assertIn("count 3; observed 2", result.stderr)

    def test_three_claims_complete_actual_helper_assertions(self):
        result, _, calls = self.execute("register-and-assert.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        registered = [
            call
            for call in calls
            if call[:2] == ["patch", "nodeclaim"] and "Registered" in call[-1]
        ]
        self.assertEqual(len(registered), 3)

    def test_followup_helpers_bound_preceding_claim_cleanup(self):
        for script in ["fallback-and-assert.sh", "small-nodes-fall-back.sh"]:
            with self.subTest(script=script):
                result, elapsed, _ = self.execute(script)
                self.assertNotEqual(result.returncode, 0)
                self.assertLess(elapsed, 4)
                self.assertIn("count 0; observed 3", result.stderr)


if __name__ == "__main__":
    unittest.main()
