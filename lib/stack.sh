#!/bin/bash
# stack.sh — Stack auto-detection and Docker image management for ccd

CCD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKER_DIR="$CCD_DIR/docker"

# Auto-detect the stack from project files
# Usage: ccd_detect_stack <project_path>
ccd_detect_stack() {
    local project_path="$1"

    # Check for project-level .ccd.yaml override
    if [ -f "$project_path/.ccd.yaml" ]; then
        local stack
        stack=$(grep -E '^stack:' "$project_path/.ccd.yaml" 2>/dev/null | awk '{print $2}')
        if [ -n "$stack" ]; then
            echo "$stack"
            return
        fi
    fi

    # Auto-detect by marker files
    if [ -f "$project_path/Cargo.toml" ]; then
        echo "rust"
    elif [ -f "$project_path/go.mod" ]; then
        echo "go"
    elif [ -f "$project_path/pyproject.toml" ] || [ -f "$project_path/uv.lock" ] || [ -f "$project_path/requirements.txt" ]; then
        echo "python"
    elif [ -f "$project_path/package.json" ]; then
        echo "node"
    else
        echo "base"
    fi
}

# Get the Docker image name for a stack
# Usage: ccd_image_name <stack>
ccd_image_name() {
    local stack="$1"
    echo "ccd-${stack}:latest"
}

# Build the base image if needed
# Usage: ccd_build_base [--force]
ccd_build_base() {
    local force="${1:-}"
    local image="ccd-base:latest"

    if [ "$force" != "--force" ] && docker image inspect "$image" >/dev/null 2>&1; then
        # Check if Dockerfile changed since last build
        local current_hash
        current_hash=$(shasum "$DOCKER_DIR/Dockerfile.base" "$DOCKER_DIR/entrypoint.sh" 2>/dev/null | shasum | awk '{print $1}')
        local stored_hash
        stored_hash=$(docker image inspect "$image" --format '{{index .Config.Labels "ccd.build_hash"}}' 2>/dev/null || echo "")

        if [ "$current_hash" = "$stored_hash" ]; then
            return 0
        fi
    fi

    echo "[ccd] Building base image..."
    local build_hash
    build_hash=$(shasum "$DOCKER_DIR/Dockerfile.base" "$DOCKER_DIR/entrypoint.sh" 2>/dev/null | shasum | awk '{print $1}')

    docker build \
        -t "$image" \
        --label "ccd.build_hash=$build_hash" \
        -f "$DOCKER_DIR/Dockerfile.base" \
        "$DOCKER_DIR"
}

# Build a stack image if needed
# Usage: ccd_build_stack <stack> [--force]
ccd_build_stack() {
    local stack="$1"
    local force="${2:-}"

    # Base is always needed
    ccd_build_base "$force"

    if [ "$stack" = "base" ]; then
        return 0
    fi

    local stack_file="$DOCKER_DIR/stacks/${stack}.Dockerfile"
    if [ ! -f "$stack_file" ]; then
        echo "[ccd] WARNING: No stack Dockerfile for '$stack', using base image"
        return 0
    fi

    local image
    image=$(ccd_image_name "$stack")

    if [ "$force" != "--force" ] && docker image inspect "$image" >/dev/null 2>&1; then
        local current_hash
        current_hash=$(shasum "$stack_file" 2>/dev/null | awk '{print $1}')
        local stored_hash
        stored_hash=$(docker image inspect "$image" --format '{{index .Config.Labels "ccd.build_hash"}}' 2>/dev/null || echo "")

        if [ "$current_hash" = "$stored_hash" ]; then
            return 0
        fi
    fi

    echo "[ccd] Building $stack stack image..."
    local build_hash
    build_hash=$(shasum "$stack_file" 2>/dev/null | awk '{print $1}')

    docker build \
        -t "$image" \
        --label "ccd.build_hash=$build_hash" \
        -f "$stack_file" \
        "$DOCKER_DIR"
}
