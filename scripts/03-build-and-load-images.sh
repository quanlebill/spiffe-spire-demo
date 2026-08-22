#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
cd "$(dirname "$0")/.."

mkdir -p .generated

echo ">> building the workload images"
docker build -q -t frontend-workload:latest -f app/frontend/Dockerfile app
docker build -q -t backend-workload:latest  -f app/backend/Dockerfile  app
docker build -q -t zt-toolbox:latest        -f app/toolbox/Dockerfile  app

echo ">> pulling the istio images once, under the reference istioctl 1.30 actually deploys"
docker pull -q registry.istio.io/release/pilot:1.30.3
docker pull -q registry.istio.io/release/proxyv2:1.30.3

echo ">> exporting the istio images as single-platform archives"
docker image save --platform linux/amd64 registry.istio.io/release/pilot:1.30.3   -o .generated/istio-pilot-1.30.3.tar
docker image save --platform linux/amd64 registry.istio.io/release/proxyv2:1.30.3 -o .generated/istio-proxyv2-1.30.3.tar

echo ">> side-loading into geic-a"
kind load image-archive --name geic-a .generated/istio-pilot-1.30.3.tar
kind load image-archive --name geic-a .generated/istio-proxyv2-1.30.3.tar
kind load docker-image  --name geic-a frontend-workload:latest backend-workload:latest zt-toolbox:latest

echo ">> side-loading into geic-b"
kind load image-archive --name geic-b .generated/istio-pilot-1.30.3.tar
kind load image-archive --name geic-b .generated/istio-proxyv2-1.30.3.tar
kind load docker-image  --name geic-b frontend-workload:latest backend-workload:latest zt-toolbox:latest
