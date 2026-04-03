#!/bin/bash
# command.sh — Command mode: escape from Claude session to run ccd commands

# Attach to the tmux session inside the container
# Usage: _ccd_tmux_attach <container_name>
_ccd_tmux_attach() {
    local container_name="$1"
    docker exec -it "$container_name" tmux attach-session -t ccd 2>/dev/null || {
        echo "[ccd] Could not attach to tmux session."
        return 1
    }
}

# Check if VS Code is attached to a container (vscode-server process running)
# Usage: _ccd_is_vscode_attached <container_name>
_ccd_is_vscode_attached() {
    local container_name="$1"
    docker exec "$container_name" sh -c 'pgrep -f "vscode-server|code-server" >/dev/null 2>&1'
}

# Attach VS Code to the container workspace
# Usage: _ccd_vscode_attach <container_name>
_ccd_vscode_attach() {
    local container_name="$1"
    local hex
    hex=$(printf '%s' "$container_name" | xxd -p | tr -d '\n')
    code --folder-uri "vscode-remote://attached-container+${hex}/workspace"
    echo "[ccd] VS Code attached to container."
}

# Reload: re-sync project files from host and restart Claude inside the same container
# Usage: _ccd_reload <session_name> <container_name>
_ccd_reload() {
    local session_name="$1"
    local container_name="$2"

    local project_path
    project_path=$(ccd_get_project_path "$session_name")
    if [ -z "$project_path" ]; then
        echo "[ccd] ERROR: Could not determine project path."
        return 1
    fi

    local stack
    stack=$(docker inspect --format '{{index .Config.Labels "ccd.stack"}}' "$container_name" 2>/dev/null || echo "base")

    # 1. Kill the running Claude/tmux session (container stays alive via sleep)
    echo "[ccd] Stopping current Claude session..."
    docker exec "$container_name" tmux kill-session -t ccd 2>/dev/null || true

    # Keep the container alive with a background sleep while we reload
    docker exec -d "$container_name" sh -c 'sleep 300' 2>/dev/null || true

    # 2. Clean workspace and re-sync project files from host
    echo "[ccd] Cleaning workspace..."
    docker exec "$container_name" sh -c '
        cd /workspace
        git clean -fd 2>/dev/null || true
        git checkout -- . 2>/dev/null || true
        rm -rf .git 2>/dev/null || true
    '

    echo "[ccd] Re-syncing project files from host..."
    ccd_copy_in "$project_path" "$session_name" "$stack"

    # 3. Restart Claude inside tmux
    echo "[ccd] Restarting Claude Code..."
    docker exec -d "$container_name" sh -c '
        cd /workspace
        # Re-run stack setup if present
        if [ -f .ccd-setup.sh ]; then
            bash .ccd-setup.sh 2>/dev/null || true
            git add -A
            git diff --cached --quiet || git commit -q -m "ccd: post-setup"
            git tag -f ccd-snapshot
        fi
        tmux -f /home/node/.tmux.conf new-session -d -s ccd "claude --dangerously-skip-permissions"
    '

    # Wait for tmux to start
    sleep 1
    echo "[ccd] Reloaded. Re-attaching with fresh ccd..."

    # Re-exec into a fresh ccd process so host-side script changes take effect
    exec "$CCD_DIR/ccd" attach "$session_name"
}

# The interactive command loop
# Usage: ccd_command_loop <session_name>
ccd_command_loop() {
    local session_name="$1"
    local container_name
    container_name=$(ccd_container_name "$session_name")

    trap 'echo ""' INT

    while true; do
        echo ""
        echo "[ccd:$session_name] Command mode (Ctrl-a d to return here from Claude)"
        echo ""
        echo "  d, diff [path]      Show changes vs snapshot"
        echo "  s, sync [--path]    Sync changes to host"
        echo "  o, open             Attach VS Code to container"
        echo "  R, reload           Pull latest ccd into container"
        echo "  r, resume (Enter)   Reattach to Claude session"
        echo "  e, exit             Leave container running"
        echo "  q, quit             Stop and optionally remove container"
        echo ""
        read -r -p "[ccd:$session_name]> " cmd args || break

        case "$cmd" in
            d|diff)
                # Stage all changes so VS Code SCM picks them up
                docker exec "$container_name" sh -c 'cd /workspace && git add -A' 2>/dev/null || true
                # Debug: check for vscode-server process
                echo "[ccd] DEBUG: checking for vscode-server in container..."
                docker exec "$container_name" sh -c 'ps aux 2>/dev/null | grep -i "vscode\|code-server" | grep -v grep || echo "(no vscode processes found)"'
                # If VS Code is attached, open the diff there
                if _ccd_is_vscode_attached "$container_name"; then
                    echo "[ccd] Opening diff in VS Code..."
                    local hex
                    hex=$(printf '%s' "$container_name" | xxd -p | tr -d '\n')
                    # Open the git diff view in VS Code
                    code --folder-uri "vscode-remote://attached-container+${hex}/workspace" \
                         --goto /workspace 2>/dev/null || true
                    # Also show summary in terminal
                    docker exec "$container_name" git -C /workspace diff --stat ccd-snapshot
                else
                    ccd_diff "$session_name" "$args"
                fi
                ;;
            s|sync)
                local project_path
                project_path=$(ccd_get_project_path "$session_name")
                if [ -n "$project_path" ]; then
                    ccd_sync "$session_name" "$project_path" "$args"
                else
                    echo "[ccd] ERROR: Could not determine project path."
                fi
                ;;
            o|open)
                _ccd_vscode_attach "$container_name"
                ;;
            R|reload)
                _ccd_reload "$session_name" "$container_name"
                ;;
            r|resume|"")
                if ! docker exec "$container_name" tmux has-session -t ccd 2>/dev/null; then
                    echo "[ccd] Claude session has ended."
                    break
                fi
                _ccd_tmux_attach "$container_name"
                # After detach/return, check if session still alive
                if ! docker exec "$container_name" tmux has-session -t ccd 2>/dev/null; then
                    echo ""
                    echo "[ccd] Claude session ended."
                    break
                fi
                ;;
            e|exit)
                echo "[ccd] Container left running. Reattach with: ccd attach $session_name"
                break
                ;;
            q|quit)
                read -r -p "[ccd] Stop container and remove? [y/N] " confirm
                if [[ "${confirm:-}" =~ ^[Yy] ]]; then
                    ccd_remove_session "$session_name"
                else
                    docker stop "$container_name" >/dev/null 2>&1 || true
                    echo "[ccd] Container stopped. Remove with: ccd rm $session_name"
                fi
                break
                ;;
            *)
                echo "[ccd] Unknown command: $cmd"
                ;;
        esac
    done

    trap - INT
}
