#!/bin/bash
# session.sh — Session naming, listing, and management for ccd

CCD_LABEL="ccd.managed=true"

# Generate a unique session name from a project path
# Usage: ccd_session_name <project_path>
ccd_session_name() {
    local project_path="$1"
    local basename
    basename=$(basename "$(realpath "$project_path")")
    local hash
    hash=$(echo "$project_path-$$-$(date +%s)" | shasum | head -c 4)
    echo "${basename}-${hash}"
}

# Convert a session name to a Docker container name
# Usage: ccd_container_name <session_name>
ccd_container_name() {
    echo "ccd-$1"
}

# List all ccd sessions (strips the ccd- container prefix for display)
# Usage: ccd_list_sessions
ccd_list_sessions() {
    docker ps -a \
        --filter "label=$CCD_LABEL" \
        --format "{{.Names}}\t{{.Status}}\t{{.Label \"ccd.project\"}}\t{{.Label \"ccd.stack\"}}\t{{.CreatedAt}}" | \
        sed 's/^ccd-//' | \
        column -t -s $'\t' | \
        (echo "NAME  STATUS  PROJECT  STACK  CREATED" && cat)
}

# Get the project path stored as a label on the container
# Usage: ccd_get_project_path <session_name>
ccd_get_project_path() {
    local container
    container=$(ccd_container_name "$1")
    docker inspect --format '{{index .Config.Labels "ccd.project_path"}}' "$container" 2>/dev/null
}

# Check if a session exists and is running
# Usage: ccd_session_status <session_name>
ccd_session_status() {
    local container
    container=$(ccd_container_name "$1")
    docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo "not_found"
}

# Remove a session container
# Usage: ccd_remove_session <session_name>
ccd_remove_session() {
    local session_name="$1"
    local container
    container=$(ccd_container_name "$session_name")
    local status
    status=$(ccd_session_status "$session_name")

    if [ "$status" = "running" ]; then
        echo "[ccd] Stopping $session_name..."
        docker stop "$container" >/dev/null
    fi

    docker rm "$container" >/dev/null 2>&1
    echo "[ccd] Removed session $session_name"
}

# Remove all stopped ccd sessions
# Usage: ccd_clean_sessions
ccd_clean_sessions() {
    local stopped
    stopped=$(docker ps -a --filter "label=$CCD_LABEL" --filter "status=exited" --format "{{.Names}}")

    if [ -z "$stopped" ]; then
        echo "[ccd] No stopped sessions to clean."
        return 0
    fi

    echo "[ccd] Removing stopped sessions:"
    for container in $stopped; do
        echo "  ${container#ccd-}"
        docker rm "$container" >/dev/null 2>&1
    done
    echo "[ccd] Done."
}

# Attach to a running session
# Usage: ccd_attach_session <session_name>
ccd_attach_session() {
    local session_name="$1"
    local container
    container=$(ccd_container_name "$session_name")
    local status
    status=$(ccd_session_status "$session_name")

    if [ "$status" != "running" ]; then
        echo "[ccd] ERROR: Session $session_name is not running (status: $status)"
        return 1
    fi

    docker attach "$container"
}
