import asyncio
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Request

from shared.mutual_tls import (
    load_client_ssl_context,
    load_server_ssl_context,
    open_mutual_tls_connection,
    run_mutual_tls_asgi_server,
    send_json_request,
    wait_for_svid_files,
)

BACKEND_SPIFFE_ID = "spiffe://ndip/backend"
BACKEND_HOST = "backend-workload-service"
BACKEND_PORT = 8443
LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = 8443
SVID_CERTIFICATE_PATH = Path("/run/spire/svids/svid.0.pem")
SVID_PRIVATE_KEY_PATH = Path("/run/spire/svids/svid.0.key")
TRUST_BUNDLE_PATH = Path("/run/spire/svids/bundle.0.pem")

application = FastAPI()
received_replies = []


def require_backend_workload_identity(request: Request):
    requester_spiffe_id = request.scope.get("workload_spiffe_id")
    if requester_spiffe_id != BACKEND_SPIFFE_ID:
        print(f"rejected request from unauthorized workload identity: {requester_spiffe_id}", flush=True)
        raise HTTPException(status_code=403, detail="only the backend workload may call this endpoint")


@application.post("/receive-reply")
async def receive_reply(request: Request, authorized=Depends(require_backend_workload_identity)):
    request_payload = await request.json()
    reply_message = request_payload.get("reply", "")
    print(f"received reply from {request.scope.get('workload_spiffe_id')}: {reply_message}", flush=True)
    received_replies.append(reply_message)
    return {"status": "reply received"}


async def send_message_to_backend(message_text):
    client_ssl_context = load_client_ssl_context(SVID_CERTIFICATE_PATH, SVID_PRIVATE_KEY_PATH, TRUST_BUNDLE_PATH)
    reader, writer, peer_spiffe_id = await open_mutual_tls_connection(BACKEND_HOST, BACKEND_PORT, client_ssl_context)
    if peer_spiffe_id != BACKEND_SPIFFE_ID:
        print(f"refusing to send message, unexpected peer identity: {peer_spiffe_id}", flush=True)
        writer.close()
        await writer.wait_closed()
        return
    await send_json_request(reader, writer, BACKEND_HOST, "/receive-message", {"message": message_text})
    print(f"sent message to {peer_spiffe_id}: {message_text}", flush=True)


async def send_initial_message_after_startup():
    await asyncio.sleep(5)
    await send_message_to_backend("hello from frontend")


async def start_server():
    wait_for_svid_files(SVID_CERTIFICATE_PATH, SVID_PRIVATE_KEY_PATH, TRUST_BUNDLE_PATH, timeout_seconds=30)
    server_ssl_context = load_server_ssl_context(SVID_CERTIFICATE_PATH, SVID_PRIVATE_KEY_PATH, TRUST_BUNDLE_PATH)
    print(f"frontend workload listening with mutual tls on {LISTEN_HOST}:{LISTEN_PORT}", flush=True)
    asyncio.create_task(send_initial_message_after_startup())
    await run_mutual_tls_asgi_server(application, LISTEN_HOST, LISTEN_PORT, server_ssl_context)


if __name__ == "__main__":
    asyncio.run(start_server())
