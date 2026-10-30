"""Forward loopback ports to the tailnet Mila journey fixture (ADR-0264).

macOS and Windows journey jobs reach the Linux job's fixture over Tailscale.
The fixture's TLS names, trust document management host and Porsche
certificate principal are all `localhost`. This forwarder listens on
127.0.0.1 with the same port numbers and relays each connection to the
fixture's tailnet address, so those names still match. It never reads,
logs or alters relayed bytes.

usage: mila-tailnet-forward.py TAILNET_ADDRESS PORT [PORT ...]
"""

import asyncio
import ipaddress
import sys
from collections.abc import Awaitable, Callable

CHUNK = 65536
Handler = Callable[[asyncio.StreamReader, asyncio.StreamWriter], Awaitable[None]]


async def pump(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    """@cc [owner:ghuntley,label:verification;security] mila-tailnet-forward-opaque
    The forwarder MUST relay bytes unchanged and MUST NOT read, log or retain
    relayed content; it MUST listen only on 127.0.0.1 so the tailnet fixture is
    not exposed beyond the runner.
    """
    try:
        while data := await reader.read(CHUNK):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        writer.close()


def relay(target: str, port: int) -> Handler:
    async def handle(
        client_reader: asyncio.StreamReader, client_writer: asyncio.StreamWriter
    ) -> None:
        try:
            upstream_reader, upstream_writer = await asyncio.open_connection(target, port)
        except OSError:
            client_writer.close()
            return
        await asyncio.gather(
            pump(client_reader, upstream_writer), pump(upstream_reader, client_writer)
        )

    return handle


async def serve(target: str, ports: list[int]) -> None:
    servers = [await asyncio.start_server(relay(target, port), "127.0.0.1", port) for port in ports]
    print(f"forwarding {len(servers)} loopback ports to the tailnet fixture", flush=True)
    await asyncio.gather(*(server.serve_forever() for server in servers))


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    target = str(ipaddress.ip_address(sys.argv[1]))
    ports = [int(value) for value in sys.argv[2:]]
    if not all(1024 <= port <= 65535 for port in ports):
        raise SystemExit("ports must be unprivileged")
    asyncio.run(serve(target, ports))


if __name__ == "__main__":
    main()
