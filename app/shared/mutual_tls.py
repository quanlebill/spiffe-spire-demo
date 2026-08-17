import asyncio
import json
import ssl
import time

from cryptography import x509


def wait_for_svid_files(certificate_path, private_key_path, trust_bundle_path, timeout_seconds):
    required_paths = [certificate_path, private_key_path, trust_bundle_path]
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if all(path.exists() for path in required_paths):
            return
        time.sleep(1)
    missing_paths = [str(path) for path in required_paths if not path.exists()]
    raise FileNotFoundError(f"svid files were not found before timeout: {missing_paths}")


def load_server_ssl_context(certificate_path, private_key_path, trust_bundle_path):
    ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ssl_context.load_cert_chain(certfile=str(certificate_path), keyfile=str(private_key_path))
    ssl_context.load_verify_locations(cafile=str(trust_bundle_path))
    ssl_context.verify_mode = ssl.CERT_REQUIRED
    return ssl_context


def load_client_ssl_context(certificate_path, private_key_path, trust_bundle_path):
    ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ssl_context.load_cert_chain(certfile=str(certificate_path), keyfile=str(private_key_path))
    ssl_context.load_verify_locations(cafile=str(trust_bundle_path))
    ssl_context.check_hostname = False
    ssl_context.verify_mode = ssl.CERT_REQUIRED
    return ssl_context


def extract_spiffe_id_from_der_certificate(der_certificate_bytes):
    certificate = x509.load_der_x509_certificate(der_certificate_bytes)
    subject_alternative_names = certificate.extensions.get_extension_for_class(x509.SubjectAlternativeName)
    uniform_resource_identifiers = subject_alternative_names.value.get_values_for_type(x509.UniformResourceIdentifier)
    return uniform_resource_identifiers[0] if uniform_resource_identifiers else None


async def open_mutual_tls_connection(host, port, ssl_context):
    reader, writer = await asyncio.open_connection(host, port, ssl=ssl_context)
    ssl_object = writer.get_extra_info("ssl_object")
    peer_certificate_der = ssl_object.getpeercert(binary_form=True)
    peer_spiffe_id = extract_spiffe_id_from_der_certificate(peer_certificate_der)
    return reader, writer, peer_spiffe_id


async def send_json_request(reader, writer, host, path, json_payload):
    request_body = json.dumps(json_payload).encode()
    request_head = (
        f"POST {path} HTTP/1.1\r\n"
        f"Host: {host}\r\n"
        f"Content-Type: application/json\r\n"
        f"Content-Length: {len(request_body)}\r\n"
        f"Connection: close\r\n"
        f"\r\n"
    ).encode()
    writer.write(request_head + request_body)
    await writer.drain()

    status_line = await reader.readline()
    status_code = int(status_line.decode().split(" ")[1])
    while True:
        header_line = await reader.readline()
        if header_line in (b"\r\n", b""):
            break
    response_body = await reader.read()
    writer.close()
    await writer.wait_closed()
    return status_code, json.loads(response_body) if response_body else None


async def run_mutual_tls_asgi_server(application, host, port, ssl_context):
    async def handle_client_connection(reader, writer):
        await dispatch_request_to_application(reader, writer, application)

    server = await asyncio.start_server(handle_client_connection, host, port, ssl=ssl_context)
    async with server:
        await server.serve_forever()


async def dispatch_request_to_application(reader, writer, application):
    ssl_object = writer.get_extra_info("ssl_object")
    peer_certificate_der = ssl_object.getpeercert(binary_form=True)
    peer_spiffe_id = extract_spiffe_id_from_der_certificate(peer_certificate_der)

    request_line = await reader.readline()
    method, path, _ = request_line.decode().strip().split(" ")

    request_headers = []
    content_length = 0
    while True:
        header_line = await reader.readline()
        if header_line in (b"\r\n", b""):
            break
        header_name, header_value = header_line.decode().strip().split(":", 1)
        header_name = header_name.strip().lower()
        header_value = header_value.strip()
        request_headers.append((header_name.encode(), header_value.encode()))
        if header_name == "content-length":
            content_length = int(header_value)

    request_body = await reader.readexactly(content_length) if content_length else b""

    request_scope = {
        "type": "http",
        "asgi": {"version": "3.0", "spec_version": "2.3"},
        "http_version": "1.1",
        "scheme": "https",
        "method": method,
        "path": path,
        "raw_path": path.encode(),
        "root_path": "",
        "query_string": b"",
        "headers": request_headers,
        "client": writer.get_extra_info("peername"),
        "server": writer.get_extra_info("sockname"),
        "workload_spiffe_id": peer_spiffe_id,
    }

    request_body_delivered = False

    async def receive_asgi_event():
        nonlocal request_body_delivered
        if request_body_delivered:
            return {"type": "http.disconnect"}
        request_body_delivered = True
        return {"type": "http.request", "body": request_body, "more_body": False}

    response_status_code = 500
    response_header_list = []

    async def send_asgi_event(event):
        nonlocal response_status_code, response_header_list
        if event["type"] == "http.response.start":
            response_status_code = event["status"]
            response_header_list = event.get("headers", [])
        elif event["type"] == "http.response.body":
            response_body = event.get("body", b"")
            header_bytes = b"".join(name + b": " + value + b"\r\n" for name, value in response_header_list)
            if not any(name.lower() == b"content-length" for name, _ in response_header_list):
                header_bytes += f"Content-Length: {len(response_body)}\r\n".encode()
            status_line = f"HTTP/1.1 {response_status_code} status\r\n".encode()
            writer.write(status_line + header_bytes + b"\r\n" + response_body)
            await writer.drain()

    await application(request_scope, receive_asgi_event, send_asgi_event)
    writer.close()
    await writer.wait_closed()
