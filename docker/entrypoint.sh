#!/bin/bash
set -euo pipefail

WORKSPACE="/workspace"
SNAPSHOT_MARKER="$WORKSPACE/.ccd-initialized"

cd "$WORKSPACE"

# Wait for files to be copied in (happens after container start via docker exec)
if [ ! -f "$SNAPSHOT_MARKER" ]; then
    echo "[ccd] Waiting for project files..."
    for i in $(seq 1 60); do
        if [ -f "$SNAPSHOT_MARKER" ]; then
            break
        fi
        sleep 0.5
    done
    if [ ! -f "$SNAPSHOT_MARKER" ]; then
        echo "[ccd] ERROR: Project files were not copied in within 30s"
        exit 1
    fi
fi

# Run stack-specific setup if a hook exists
if [ -f "$WORKSPACE/.ccd-setup.sh" ]; then
    echo "[ccd] Running stack setup..."
    bash "$WORKSPACE/.ccd-setup.sh"
    # Commit setup artifacts so they don't show in diff
    git add -A
    git diff --cached --quiet || git commit -q -m "ccd: post-setup"
    # Move snapshot tag past setup so deps don't pollute the diff
    git tag -f ccd-snapshot
fi

echo "[ccd] Starting Claude Code..."
exec claude --dangerously-skip-permissions "$@"
