import asyncio
import os

from fastapi import FastAPI, Request

from shared.http_transport import open_http_connection, run_http_asgi_server, send_json_request
from shared.peer_identity import peer_spiffe_id_from_headers

SERVICE_NAME = os.environ.get("SERVICE_NAME", "backend")
CLUSTER_NAME = os.environ.get("CLUSTER_NAME", "unknown")
SPIFFE_ID = os.environ.get("SPIFFE_ID", "unknown")
LISTEN_HOST = os.environ.get("LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8080"))

application = FastAPI()
received_messages = []


@application.get("/whoami")
async def whoami():
    return {"service": SERVICE_NAME, "cluster": CLUSTER_NAME, "spiffe_id": SPIFFE_ID, "listening_on": f"{LISTEN_HOST}:{LISTEN_PORT}"}


@application.post("/receive-message")
async def receive_message(request: Request):
    request_payload = await request.json()
    incoming_message = request_payload.get("message", "")
    caller_spiffe_id = peer_spiffe_id_from_headers(request)
    print(f"received message: {incoming_message} from {caller_spiffe_id}", flush=True)
    received_messages.append({"message": incoming_message, "caller": caller_spiffe_id})
    return {
        "status": "message received",
        "handled_by": SERVICE_NAME,
        "handled_in_cluster": CLUSTER_NAME,
        "verified_caller": caller_spiffe_id,
    }


@application.get("/messages")
async def messages():
    return {"service": SERVICE_NAME, "received": received_messages}


@application.get("/send")
async def send(request: Request):
    target_host = request.query_params.get("host", "frontend")
    target_port = int(request.query_params.get("port", "8080"))
    reply_message = request.query_params.get("message", "hello from backend")
    try:
        reader, writer = await asyncio.wait_for(open_http_connection(target_host, target_port), timeout=10)
        status_code, response_body = await asyncio.wait_for(
            send_json_request(reader, writer, target_host, "/receive-reply", {"reply": reply_message}), timeout=10
        )
        return {"target": f"{target_host}:{target_port}", "status_code": status_code, "body": response_body}
    except Exception as error:
        return {"target": f"{target_host}:{target_port}", "status_code": None, "error": f"{type(error).__name__}: {error}"}


async def start_server():
    print(f"{SERVICE_NAME} ({SPIFFE_ID}) in {CLUSTER_NAME} listening on {LISTEN_HOST}:{LISTEN_PORT}, mtls handled by the envoy sidecar", flush=True)
    await run_http_asgi_server(application, LISTEN_HOST, LISTEN_PORT)


if __name__ == "__main__":
    asyncio.run(start_server())
