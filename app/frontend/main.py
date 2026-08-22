import asyncio
import os

from fastapi import FastAPI, Request

from shared.http_transport import open_http_connection, run_http_asgi_server, send_json_request
from shared.peer_identity import peer_spiffe_id_from_headers

SERVICE_NAME = os.environ.get("SERVICE_NAME", "frontend")
CLUSTER_NAME = os.environ.get("CLUSTER_NAME", "unknown")
SPIFFE_ID = os.environ.get("SPIFFE_ID", "unknown")
BACKEND_HOST = os.environ.get("BACKEND_HOST", "backend")
BACKEND_PORT = int(os.environ.get("BACKEND_PORT", "8080"))
LISTEN_HOST = os.environ.get("LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8080"))

application = FastAPI()
received_replies = []


@application.get("/whoami")
async def whoami():
    return {"service": SERVICE_NAME, "cluster": CLUSTER_NAME, "spiffe_id": SPIFFE_ID, "listening_on": f"{LISTEN_HOST}:{LISTEN_PORT}"}


@application.post("/receive-reply")
async def receive_reply(request: Request):
    request_payload = await request.json()
    reply_message = request_payload.get("reply", "")
    caller_spiffe_id = peer_spiffe_id_from_headers(request)
    print(f"received reply: {reply_message} from {caller_spiffe_id}", flush=True)
    received_replies.append({"reply": reply_message, "caller": caller_spiffe_id})
    return {"status": "reply received"}


@application.get("/replies")
async def replies():
    return {"service": SERVICE_NAME, "received": received_replies}


@application.get("/send")
async def send(request: Request):
    target_host = request.query_params.get("host", BACKEND_HOST)
    target_port = int(request.query_params.get("port", BACKEND_PORT))
    message_text = request.query_params.get("message", "hello from frontend")
    return await send_message_to_backend(target_host, target_port, message_text)


async def send_message_to_backend(target_host, target_port, message_text):
    try:
        reader, writer = await asyncio.wait_for(open_http_connection(target_host, target_port), timeout=10)
        status_code, response_body = await asyncio.wait_for(
            send_json_request(reader, writer, target_host, "/receive-message", {"message": message_text}), timeout=10
        )
        print(f"sent message to {target_host}:{target_port} -> {status_code} {response_body}", flush=True)
        return {"target": f"{target_host}:{target_port}", "status_code": status_code, "body": response_body}
    except Exception as error:
        print(f"call to {target_host}:{target_port} failed: {type(error).__name__}: {error}", flush=True)
        return {"target": f"{target_host}:{target_port}", "status_code": None, "error": f"{type(error).__name__}: {error}"}


async def start_server():
    print(f"{SERVICE_NAME} ({SPIFFE_ID}) in {CLUSTER_NAME} listening on {LISTEN_HOST}:{LISTEN_PORT}, mtls handled by the envoy sidecar", flush=True)
    await run_http_asgi_server(application, LISTEN_HOST, LISTEN_PORT)


if __name__ == "__main__":
    asyncio.run(start_server())
