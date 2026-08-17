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

FRONTEND_SPIFFE_ID = "spiffe://ndip/frontend"
FRONTEND_HOST = "frontend-workload-service"
FRONTEND_PORT = 8443
LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = 8443
SVID_CERTIFICATE_PATH = Path("/run/spire/svids/svid.0.pem")
SVID_PRIVATE_KEY_PATH = Path("/run/spire/svids/svid.0.key")
TRUST_BUNDLE_PATH = Path("/run/spire/svids/bundle.0.pem")

application = FastAPI()


def require_frontend_workload_identity(request: Request):
    requester_spiffe_id = request.scope.get("workload_spiffe_id")
    if requester_spiffe_id != FRONTEND_SPIFFE_ID:
        print(f"rejected request from unauthorized workload identity: {requester_spiffe_id}", flush=True)
        raise HTTPException(status_code=403, detail="only the frontend workload may call this endpoint")


@application.post("/receive-message")
async def receive_message(request: Request, authorized=Depends(require_frontend_workload_identity)):
    request_payload = await request.json()
    incoming_message = request_payload.get("message", "")
    print(f"received message from {request.scope.get('workload_spiffe_id')}: {incoming_message}", flush=True)
    reply_message = f"backend received: {incoming_message}"
    asyncio.create_task(deliver_reply_to_frontend(reply_message))
    return {"status": "message received"}


async def deliver_reply_to_frontend(reply_message):
    client_ssl_context = load_client_ssl_context(SVID_CERTIFICATE_PATH, SVID_PRIVATE_KEY_PATH, TRUST_BUNDLE_PATH)
    reader, writer, peer_spiffe_id = await open_mutual_tls_connection(FRONTEND_HOST, FRONTEND_PORT, client_ssl_context)
    if peer_spiffe_id != FRONTEND_SPIFFE_ID:
        print(f"refusing to send reply, unexpected peer identity: {peer_spiffe_id}", flush=True)
        writer.close()
        await writer.wait_closed()
        return
    await send_json_request(reader, writer, FRONTEND_HOST, "/receive-reply", {"reply": reply_message})
    print(f"sent reply to {peer_spiffe_id}: {reply_message}", flush=True)


async def start_server():
    wait_for_svid_files(SVID_CERTIFICATE_PATH, SVID_PRIVATE_KEY_PATH, TRUST_BUNDLE_PATH, timeout_seconds=30)
    server_ssl_context = load_server_ssl_context(SVID_CERTIFICATE_PATH, SVID_PRIVATE_KEY_PATH, TRUST_BUNDLE_PATH)
    print(f"backend workload listening with mutual tls on {LISTEN_HOST}:{LISTEN_PORT}", flush=True)
    await run_mutual_tls_asgi_server(application, LISTEN_HOST, LISTEN_PORT, server_ssl_context)


if __name__ == "__main__":
    asyncio.run(start_server())
