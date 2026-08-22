FROM python:3.12-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl openssl iproute2 dnsutils netcat-openbsd procps \
 && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir cryptography==44.0.0

WORKDIR /app
COPY shared ./shared
COPY toolbox/forge_certificate.py ./forge_certificate.py

USER 1000
CMD ["sleep", "infinity"]
