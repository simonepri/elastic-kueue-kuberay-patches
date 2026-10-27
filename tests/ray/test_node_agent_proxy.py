"""Check that the Ray head reaches other nodes' agents over HTTP through the gRPC CONNECT proxy.

Runs inside a Ray image with `python -m unittest`; it fails on the stock image and
passes once patches/ray is applied.
"""

import asyncio
import os
import socket
import unittest
from unittest import mock

os.environ["RAY_grpc_enable_http_proxy"] = "1"

from aiohttp import web  # noqa: E402

from ray.core.generated.runtime_env_agent_pb2 import GetRuntimeEnvsInfoReply  # noqa: E402
from ray.dashboard.modules.job.job_head import JobAgentSubmissionClient  # noqa: E402
from ray.util.state.state_manager import StateDataSourceClient  # noqa: E402

# A name that resolves nowhere: only the proxy can reach it.
WORKER_HOST = "worker-node.invalid"


async def _get_runtime_envs_info(request):
    return web.Response(body=GetRuntimeEnvsInfoReply(total=7).SerializeToString())


async def _get_job_logs(request):
    return web.json_response({"logs": f"logs of {request.match_info['job_id']}"})


async def _tail_job_logs(request):
    ws = web.WebSocketResponse()
    await ws.prepare(request)
    await ws.send_str("tailed line")
    await ws.close()
    return ws


class ConnectProxy:
    """An HTTP CONNECT proxy that tunnels every target to one local port."""

    def __init__(self, upstream_port):
        self.upstream_port = upstream_port
        self.targets = []

    async def start(self):
        self.server = await asyncio.start_server(self._handle, "127.0.0.1", 0)
        self.port = self.server.sockets[0].getsockname()[1]

    async def stop(self):
        self.server.close()
        await self.server.wait_closed()

    async def _handle(self, reader, writer):
        head = await reader.readuntil(b"\r\n\r\n")
        method, target, _ = head.split(b"\r\n", 1)[0].decode().split(" ")
        if method != "CONNECT":
            writer.write(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")
            writer.close()
            return
        self.targets.append(target)
        up_reader, up_writer = await asyncio.open_connection(
            "127.0.0.1", self.upstream_port
        )
        writer.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
        await asyncio.gather(
            self._pipe(reader, up_writer), self._pipe(up_reader, writer)
        )

    @staticmethod
    async def _pipe(reader, writer):
        try:
            while data := await reader.read(65536):
                writer.write(data)
                await writer.drain()
        finally:
            writer.close()


class NodeAgentProxyTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        app = web.Application()
        app.router.add_post("/get_runtime_envs_info", _get_runtime_envs_info)
        app.router.add_get("/api/job_agent/jobs/{job_id}/logs", _get_job_logs)
        app.router.add_get("/api/job_agent/jobs/{job_id}/logs/tail", _tail_job_logs)
        self.runner = web.AppRunner(app)
        await self.runner.setup()
        sock = socket.create_server(("127.0.0.1", 0))
        self.agent_port = sock.getsockname()[1]
        await web.SockSite(self.runner, sock).start()

        self.proxy = ConnectProxy(self.agent_port)
        await self.proxy.start()
        env = {"grpc_proxy": f"http://127.0.0.1:{self.proxy.port}"}
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        for name in ("no_grpc_proxy", "no_proxy", "https_proxy", "http_proxy"):
            os.environ.pop(name, None)

    async def asyncTearDown(self):
        await self.proxy.stop()
        await self.runner.cleanup()

    async def test_state_api_runtime_envs_use_proxy(self):
        client = StateDataSourceClient(mock.MagicMock(), mock.MagicMock())
        try:
            reply = await asyncio.wait_for(
                client.get_runtime_envs_info(WORKER_HOST, self.agent_port, timeout=10),
                20,
            )
        finally:
            await client._client_session.close()
        self.assertEqual(reply.total, 7)
        self.assertEqual(self.proxy.targets, [f"{WORKER_HOST}:{self.agent_port}"])

    async def test_job_driver_agent_uses_proxy(self):
        client = JobAgentSubmissionClient(f"http://{WORKER_HOST}:{self.agent_port}")
        try:
            logs = await asyncio.wait_for(client.get_job_logs_internal("job-1"), 20)
            lines = [line async for line in client.tail_job_logs("job-1")]
        finally:
            await client.close()
        self.assertEqual(logs.logs, "logs of job-1")
        self.assertEqual(lines, ["tailed line"])
        self.assertTrue(self.proxy.targets)
        self.assertEqual(set(self.proxy.targets), {f"{WORKER_HOST}:{self.agent_port}"})

    async def test_no_grpc_proxy_connects_directly(self):
        os.environ["no_grpc_proxy"] = "example.com,127.0.0.0/8"
        client = StateDataSourceClient(mock.MagicMock(), mock.MagicMock())
        try:
            reply = await client.get_runtime_envs_info(
                "127.0.0.1", self.agent_port, timeout=10
            )
        finally:
            await client._client_session.close()
        self.assertEqual(reply.total, 7)
        self.assertEqual(self.proxy.targets, [])


if __name__ == "__main__":
    unittest.main()
