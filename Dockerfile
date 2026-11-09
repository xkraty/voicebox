# syntax=docker/dockerfile:1.7
#
# Voicebox (github.com/jamiepine/voicebox) with Caddy basic auth in front,
# deployed with Kamal. Voicebox publishes no image, so this builds it from
# source at VOICEBOX_REF, following upstream's Dockerfile at that commit with
# three changes:
#
#   1. CPU-only PyTorch. Upstream's default "cpu" variant still pulls the CUDA
#      build from PyPI (~3 GB of nvidia-* wheels the server can't use).
#   2. No chatterbox-tts. LuxTTS only; Voicebox imports engines lazily, so the
#      server runs fine without it.
#   3. Caddy on :8080 (Kamal's app_port) does basic auth and proxies to
#      Voicebox on 127.0.0.1:17493, which is never exposed.
#
# Upgrading: bump VOICEBOX_REF, then diff upstream's Dockerfile between the old
# and new commit and carry over any build changes.

ARG VOICEBOX_REF=8af7efe62fab8d33e2a5dfbedabaa45f68a5184f

# === Upstream source at the pinned commit ===
FROM scratch AS source
ARG VOICEBOX_REF
ADD https://github.com/jamiepine/voicebox.git#${VOICEBOX_REF} /


# === Stage 1: Build frontend ===
# Runs on the build machine's native platform: the output is static JS/CSS,
# and Bun crashes under QEMU/Rosetta when an arm64 Mac cross-builds amd64.
FROM --platform=$BUILDPLATFORM oven/bun:1 AS frontend
WORKDIR /build

COPY --from=source /package.json /bun.lock /CHANGELOG.md ./
COPY --from=source /app/ ./app/
COPY --from=source /web/ ./web/

# Strip the tauri workspace (desktop only) and fix the trailing comma it leaves
RUN sed -i 's/\r$//' package.json && \
    sed -i '/"tauri"/d' package.json && \
    sed -i -z 's/,\n  ]/\n  ]/' package.json
RUN bun install --no-save
RUN cd web && bunx --bun vite build


# === Stage 2: Build Python dependencies ===
FROM python:3.12-slim AS backend-builder
WORKDIR /build

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir --upgrade pip

COPY --from=source /backend/requirements.txt .

# Make PyTorch's CPU index primary so every install below resolves torch and
# torchaudio to CPU wheels (same mechanism upstream uses for ROCm).
RUN printf '[global]\nindex-url = https://download.pytorch.org/whl/cpu\nextra-index-url = https://pypi.org/simple\n' > /etc/pip.conf && \
    pip install --no-cache-dir --prefix=/install torch torchaudio

RUN pip install --no-cache-dir --prefix=/install -r requirements.txt
# (upstream installs chatterbox-tts here; skipped, LuxTTS only)
RUN pip install --no-cache-dir --prefix=/install --no-deps hume-tada
RUN pip install --no-cache-dir --prefix=/install --no-deps omnivoice
RUN pip install --no-cache-dir --prefix=/install \
    git+https://github.com/QwenLM/Qwen3-TTS.git


# === Stage 3: Runtime ===
FROM python:3.12-slim

RUN groupadd -r voicebox && \
    useradd -r -g voicebox -m -s /bin/bash voicebox

RUN mkdir -p /home/voicebox/.cache/huggingface \
    && chown -R voicebox:voicebox /home/voicebox/.cache/huggingface

WORKDIR /app

# ffmpeg/sox for audio, gcc/g++ for Triton JIT, gosu for the privilege drop
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    sox \
    gcc \
    g++ \
    curl \
    gosu \
    && rm -rf /var/lib/apt/lists/*

COPY --from=backend-builder /install /usr/local
COPY --from=source --chown=voicebox:voicebox /backend/ /app/backend/
COPY --from=frontend --chown=voicebox:voicebox /build/web/dist /app/frontend/

RUN mkdir -p /app/data/generations /app/data/profiles /app/data/cache \
    && chown -R voicebox:voicebox /app/data

# Caddy: static binary, run as the voicebox user with its state under $HOME
COPY --from=caddy:2.10-alpine /usr/bin/caddy /usr/local/bin/caddy
COPY Caddyfile /etc/caddy/Caddyfile
COPY --chmod=755 bin/voice-start /usr/local/bin/voice-start
ENV XDG_CONFIG_HOME=/home/voicebox/.config \
    XDG_DATA_HOME=/home/voicebox/.local/share \
    NUMBA_CACHE_DIR=/tmp/numba_cache

EXPOSE 8080

# Upstream's entrypoint fixes volume ownership, then drops to the voicebox user
COPY --from=source --chmod=755 /scripts/rocm-entrypoint.sh /usr/local/bin/entrypoint.sh
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["voice-start"]
