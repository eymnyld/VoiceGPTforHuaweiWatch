"""Private WebSocket bridge: mono 16 kHz PCM over TLS, WebRTC to Codex Voice."""
import asyncio
import contextlib
import hmac
import json
from pathlib import Path

from aiohttp import WSMsgType, web
from aiortc import AudioStreamTrack, RTCConfiguration, RTCPeerConnection, RTCSessionDescription
from av import AudioFrame, AudioResampler


class PhoneAudio(AudioStreamTrack):
    def __init__(self):
        super().__init__()
        self.pending = bytearray()

    def append(self, data):
        self.pending.extend(data)
        # Keep at most half a second. Drop stale audio after network stalls.
        if len(self.pending) > 16000:
            del self.pending[:-16000]

    async def recv(self):
        tick = await super().recv()
        count = min(640, len(self.pending))
        data = bytes(self.pending[:count]).ljust(640, b"\0")
        del self.pending[:count]
        frame = AudioFrame(format="s16", layout="mono", samples=320)
        frame.planes[0].update(data)
        frame.sample_rate = 16000
        frame.pts = tick.pts * 2
        frame.time_base = tick.time_base / 2
        return frame


async def voice(request):
    token = (Path.home() / ".config/codex-voice/key").read_text().strip()
    if not token or not hmac.compare_digest(
        request.headers.get("Authorization", "").encode(), ("Bearer " + token).encode()
    ):
        raise web.HTTPUnauthorized()
    lock = request.app["voice_lock"]
    if lock.locked():
        raise web.HTTPConflict()
    async with lock:
        ws = web.WebSocketResponse(heartbeat=20, max_msg_size=8192)
        await ws.prepare(request)
        pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))
        phone = PhoneAudio()
        pc.addTrack(phone)
        pc.createDataChannel("oai-events")
        tracks = asyncio.Queue()
        pc.on("track", tracks.put_nowait)
        proc = None
        tasks = []

        async def send(method, params, id=None):
            message = {"method": method, "params": params}
            if id is not None:
                message["id"] = id
            proc.stdin.write(json.dumps(message).encode() + b"\n")
            await proc.stdin.drain()

        async def receive():
            line = await proc.stdout.readline()
            if not line:
                raise RuntimeError("Codex closed")
            message = json.loads(line)
            if "error" in message or message.get("method") == "thread/realtime/error":
                raise RuntimeError("Codex rejected the voice session")
            return message

        async def await_message(predicate):
            async with asyncio.timeout(20):
                while True:
                    message = await receive()
                    if predicate(message):
                        return message

        async def input_audio():
            async for message in ws:
                if message.type == WSMsgType.BINARY and len(message.data) % 2 == 0:
                    phone.append(message.data)

        async def output_audio():
            track = await tracks.get()
            resampler = AudioResampler(format="s16", layout="mono", rate=16000)
            while True:
                for frame in resampler.resample(await track.recv()):
                    await ws.send_bytes(bytes(frame.planes[0])[:frame.samples * 2])

        async def monitor():
            while True:
                message = await receive()
                if message.get("method") == "thread/realtime/closed":
                    return

        try:
            proc = await asyncio.create_subprocess_exec(
                str(Path.home() / ".local/bin/codex"), "app-server", "--listen", "stdio://",
                cwd="/tmp", stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
            await send("initialize", {
                "clientInfo": {"name": "huasideload-voice", "version": "1.0"},
                "capabilities": {"experimentalApi": True},
            }, 1)
            await await_message(lambda m: m.get("id") == 1)
            await send("initialized", {})
            await send("thread/start", {
                "ephemeral": True, "cwd": "/tmp", "sandbox": "read-only", "approvalPolicy": "never",
            }, 2)
            thread = (await await_message(lambda m: m.get("id") == 2))["result"]["thread"]["id"]
            await pc.setLocalDescription(await pc.createOffer())
            await send("thread/realtime/start", {
                "threadId": thread, "version": "v3", "outputModality": "audio",
                "includeStartupContext": False, "clientManagedHandoffs": False,
                "transport": {"type": "webrtc", "sdp": pc.localDescription.sdp},
            }, 3)
            answer = await await_message(lambda m: m.get("method") == "thread/realtime/sdp")
            await pc.setRemoteDescription(RTCSessionDescription(sdp=answer["params"]["sdp"], type="answer"))
            async with asyncio.timeout(12):
                while pc.connectionState != "connected":
                    if pc.connectionState in ("failed", "closed"):
                        raise RuntimeError("WebRTC connection failed")
                    await asyncio.sleep(0.1)
            await ws.send_str("ready")
            tasks = [asyncio.create_task(run()) for run in (input_audio, output_audio, monitor)]
            finished, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in finished:
                task.result()
        except (RuntimeError, TimeoutError, ConnectionError, OSError):
            request.app.logger.exception("Codex Voice session failed")
            with contextlib.suppress(ConnectionError, RuntimeError):
                await ws.send_str("error")
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            await pc.close()
            if proc and proc.returncode is None:
                proc.stdin.close()
                try:
                    await asyncio.wait_for(proc.wait(), 3)
                except TimeoutError:
                    proc.terminate()
                    await proc.wait()
            await ws.close()
        return ws


async def app():
    server = web.Application()
    server["voice_lock"] = asyncio.Lock()
    server.router.add_get("/codex-voice", voice)
    return server


if __name__ == "__main__":
    web.run_app(app(), host="localhost", port=18643, access_log=None)
