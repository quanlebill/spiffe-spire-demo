def peer_spiffe_id_from_headers(request):
    forwarded_client_certificate = request.headers.get("x-forwarded-client-cert")
    if not forwarded_client_certificate:
        return None
    for element in forwarded_client_certificate.split(";"):
        header_name, separator, header_value = element.partition("=")
        if separator and header_name.strip().lower() == "uri":
            return header_value.strip('"')
    return None
