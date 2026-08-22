import asyncio
import json


async def open_http_connection(host, port):
    return await asyncio.open_connection(host, port)


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
    if not response_body:
        return status_code, None
    try:
        return status_code, json.loads(response_body)
    except json.JSONDecodeError:
        return status_code, response_body.decode(errors="replace")


async def run_http_asgi_server(application, host, port):
    async def handle_client_connection(reader, writer):
        await dispatch_request_to_application(reader, writer, application)

    server = await asyncio.start_server(handle_client_connection, host, port)
    async with server:
        await server.serve_forever()


async def dispatch_request_to_application(reader, writer, application):
    request_line = await reader.readline()
    if not request_line:
        writer.close()
        return
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

    raw_path, _, query_string = path.partition("?")
    request_scope = {
        "type": "http",
        "asgi": {"version": "3.0", "spec_version": "2.3"},
        "http_version": "1.1",
        "scheme": "http",
        "method": method,
        "path": raw_path,
        "raw_path": raw_path.encode(),
        "root_path": "",
        "query_string": query_string.encode(),
        "headers": request_headers,
        "client": writer.get_extra_info("peername"),
        "server": writer.get_extra_info("sockname"),
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
