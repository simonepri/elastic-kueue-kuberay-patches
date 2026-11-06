"""Check that the reporter agent spreads its node stats reports over time.

Runs inside a Ray image with `python -m unittest`; it fails on the stock image and
passes once patches/ray is applied.
"""

import asyncio
import unittest
from unittest import mock

import ray.dashboard.modules.reporter.reporter_consts as reporter_consts
from ray.dashboard.modules.reporter.reporter_agent import (
    ReporterAgent,
    _jittered_interval_s,
)


class ReporterIntervalJitterTest(unittest.TestCase):
    def test_interval_stays_within_bounds_and_varies(self):
        waits = [_jittered_interval_s(5000, 0.2) for _ in range(1000)]
        self.assertTrue(all(4.0 <= wait <= 6.0 for wait in waits))
        # A fixed interval would put every node in lockstep.
        self.assertGreater(max(waits) - min(waits), 1.0)

    def test_interval_without_jitter_is_the_base_interval(self):
        self.assertEqual(_jittered_interval_s(5000, 0), 5.0)

    def test_run_loop_staggers_first_report_and_jitters_waits(self):
        sleeps = []
        published = []

        async def fake_sleep(seconds):
            sleeps.append(seconds)
            if len(sleeps) == 20:
                raise asyncio.CancelledError

        async def publish(key, payload):
            published.append(payload)

        agent = mock.MagicMock()
        agent._is_head_node = False
        agent._executor = None
        agent._run_in_executor = lambda *_: "payload"
        agent._gcs_client.async_publish_node_resource_usage = publish

        with mock.patch.object(
            reporter_consts, "REPORTER_UPDATE_INTERVAL_MS", 5000
        ), mock.patch.object(
            reporter_consts, "REPORTER_UPDATE_INTERVAL_JITTER_FRACTION", 0.2
        ), mock.patch(
            "ray.dashboard.modules.reporter.reporter_agent.asyncio.sleep", fake_sleep
        ):
            with self.assertRaises(asyncio.CancelledError):
                asyncio.run(ReporterAgent._run_loop(agent))

        initial_offset, waits = sleeps[0], sleeps[1:]
        self.assertTrue(0 <= initial_offset <= 5.0)
        # The agent publishes only after its initial offset.
        self.assertEqual(len(published), len(waits))
        self.assertTrue(all(4.0 <= wait <= 6.0 for wait in waits))
        self.assertGreater(len(set(waits)), 1)


if __name__ == "__main__":
    unittest.main()
