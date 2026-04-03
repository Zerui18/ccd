FROM ccd-base:latest

USER root

# Install Python and uv
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-venv \
    python3-dev \
    && rm -rf /var/lib/apt/lists/*

# Install uv (fast Python package manager)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

USER node

# Configure uv to use a consistent cache and venv location
ENV UV_CACHE_DIR=/home/node/.cache/uv
ENV UV_PYTHON_PREFERENCE=system
