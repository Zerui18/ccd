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

# Override tmux prefix key if configured
if [ -n "${CCD_PREFIX_KEY:-}" ]; then
    tmux set-option -g prefix "C-${CCD_PREFIX_KEY}" 2>/dev/null || true
fi

# Build the Claude command wrapper script (preserves argument quoting through tmux)
cat > /tmp/ccd-run.sh <<RUNCMD
#!/bin/bash
exec claude --dangerously-skip-permissions $(printf '%q ' "$@")
RUNCMD
chmod +x /tmp/ccd-run.sh

# Launch: via tmux (interactive) or directly (print/pipe mode)
echo "[ccd] Starting Claude Code..."
if [ "${CCD_TMUX:-0}" = "1" ]; then
    echo "[ccd] Press Ctrl-a d to enter command mode."
    # Start tmux in background — entrypoint stays alive as PID 1
    # so the container survives tmux restarts (needed for reload)
    tmux -f /home/node/.tmux.conf new-session -d -s ccd /tmp/ccd-run.sh

    # Wait for tmux to exit (Claude quit or session killed)
    # Re-check in a loop so reloads can start a new tmux session
    while true; do
        if ! tmux has-session -t ccd 2>/dev/null; then
            # tmux session gone — check if a new one appeared (reload case)
            sleep 1
            if ! tmux has-session -t ccd 2>/dev/null; then
                # No new session after 1s — Claude truly exited
                break
            fi
        fi
        sleep 1
    done
else
    exec /tmp/ccd-run.sh
fi
