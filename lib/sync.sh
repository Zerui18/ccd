#!/bin/bash
# sync.sh — File copy-in and patch-out logic for ccd

# Copy project files into a container
# For git repos: git bundle + clone + apply uncommitted changes
# Usage: ccd_copy_in <project_path> <session_name> <stack>
ccd_copy_in() {
    local project_path="$1"
    local container_name
    container_name=$(ccd_container_name "$2")
    local stack="$3"

    echo "[ccd] Copying project files into container..."

    if [ -d "$project_path/.git" ]; then
        _copy_in_git "$project_path" "$container_name"
    else
        _copy_in_tar "$project_path" "$container_name"
    fi

    # Copy stack setup script if detected
    if [ -n "$stack" ]; then
        local setup_script
        setup_script=$(ccd_generate_setup_script "$stack")
        if [ -n "$setup_script" ]; then
            echo "$setup_script" | docker exec -i "$container_name" sh -c 'cat > /workspace/.ccd-setup.sh'
        fi
    fi

    # Signal entrypoint that files are ready
    docker exec "$container_name" touch /workspace/.ccd-initialized
}

# Git-based copy-in: bundle the repo, clone inside container, layer uncommitted changes
_copy_in_git() {
    local project_path="$1"
    local container_name="$2"

    # 1. Bundle the entire repo and clone it inside the container
    echo "[ccd]   Bundling git repo..."
    (cd "$project_path" && git bundle create - --all) | \
        docker exec -i "$container_name" sh -c '
            git clone /dev/stdin /workspace 2>/dev/null || {
                # /workspace exists but is empty — clone into temp then move
                git clone /dev/stdin /tmp/_ccd_clone 2>/dev/null
                cp -a /tmp/_ccd_clone/. /workspace/
                rm -rf /tmp/_ccd_clone
            }
        '

    # 2. Capture uncommitted changes from the host working tree
    local has_staged=false
    local has_unstaged=false
    local has_untracked=false

    # Staged changes (index vs HEAD)
    local staged_patch
    staged_patch=$(cd "$project_path" && git diff --cached --binary 2>/dev/null) || true
    [ -n "$staged_patch" ] && has_staged=true

    # Unstaged changes (working tree vs index)
    local unstaged_patch
    unstaged_patch=$(cd "$project_path" && git diff --binary 2>/dev/null) || true
    [ -n "$unstaged_patch" ] && has_unstaged=true

    # Untracked files (not ignored)
    local untracked_files
    untracked_files=$(cd "$project_path" && git ls-files --others --exclude-standard 2>/dev/null) || true
    [ -n "$untracked_files" ] && has_untracked=true

    # 3. Apply uncommitted state inside the container
    if [ "$has_staged" = true ]; then
        echo "[ccd]   Applying staged changes..."
        echo "$staged_patch" | docker exec -i "$container_name" git -C /workspace apply --index -
    fi

    if [ "$has_unstaged" = true ]; then
        echo "[ccd]   Applying unstaged changes..."
        echo "$unstaged_patch" | docker exec -i "$container_name" git -C /workspace apply -
    fi

    if [ "$has_untracked" = true ]; then
        echo "[ccd]   Copying untracked files..."
        (cd "$project_path" && echo "$untracked_files" | \
            tar cf - --no-xattrs --no-mac-metadata -T - 2>/dev/null) | \
            docker exec -i "$container_name" tar xf - -C /workspace
    fi

    # 4. Tag this exact state as the snapshot baseline for diffing later
    docker exec "$container_name" sh -c '
        cd /workspace
        git add -A
        git diff --cached --quiet || git commit -q -m "ccd: uncommitted changes from host"
        git tag -f ccd-snapshot
    '

    echo "[ccd]   Git repo cloned with full history + working tree state."
}

# Tar-based fallback for non-git projects
_copy_in_tar() {
    local project_path="$1"
    local container_name="$2"

    tar cf - --no-xattrs --no-mac-metadata \
        --exclude='.git' \
        --exclude='node_modules' \
        --exclude='__pycache__' \
        --exclude='.venv' \
        --exclude='venv' \
        --exclude='target' \
        --exclude='.DS_Store' \
        -C "$project_path" . | \
        docker exec -i "$container_name" tar xf - -C /workspace

    # Initialize git inside container for snapshot tracking
    docker exec "$container_name" sh -c '
        cd /workspace
        git init -q
        git add -A
        git commit -q -m "ccd: initial snapshot" --allow-empty
        git tag -f ccd-snapshot
    '

    echo "[ccd]   Files copied (tar fallback, no git history)."
}

# Generate a stack-specific setup script to run inside the container
# Usage: ccd_generate_setup_script <stack>
ccd_generate_setup_script() {
    local stack="$1"
    case "$stack" in
        node)
            cat <<'SETUP'
#!/bin/bash
if [ -f package-lock.json ]; then
    npm ci 2>/dev/null || npm install
elif [ -f yarn.lock ]; then
    yarn install --frozen-lockfile 2>/dev/null || yarn install
elif [ -f pnpm-lock.yaml ]; then
    npx pnpm install --frozen-lockfile 2>/dev/null || npx pnpm install
elif [ -f package.json ]; then
    npm install
fi
SETUP
            ;;
        python)
            cat <<'SETUP'
#!/bin/bash
if [ -f uv.lock ] || [ -f pyproject.toml ]; then
    uv sync 2>/dev/null || uv pip install -e . 2>/dev/null || true
elif [ -f requirements.txt ]; then
    uv pip install -r requirements.txt 2>/dev/null || pip install -r requirements.txt
fi
SETUP
            ;;
        go)
            cat <<'SETUP'
#!/bin/bash
if [ -f go.mod ]; then
    go mod download
fi
SETUP
            ;;
        rust)
            cat <<'SETUP'
#!/bin/bash
if [ -f Cargo.toml ]; then
    cargo fetch 2>/dev/null || true
fi
SETUP
            ;;
        *)
            echo ""
            ;;
    esac
}

# Show diff of changes made inside the container (vs copy-in state)
# Usage: ccd_diff <session_name> [path_filter]
ccd_diff() {
    local container_name
    container_name=$(ccd_container_name "$1")
    local path_filter="${2:-}"

    if [ -n "$path_filter" ]; then
        docker exec "$container_name" git -C /workspace diff ccd-snapshot -- "$path_filter"
    else
        docker exec "$container_name" git -C /workspace diff ccd-snapshot
    fi

    # Also show new untracked files
    docker exec "$container_name" git -C /workspace ls-files --others --exclude-standard
}

# Extract a patch from the container and apply it to the host project
# Usage: ccd_sync <session_name> <host_project_path> [path_filter]
ccd_sync() {
    local container_name
    container_name=$(ccd_container_name "$1")
    local host_project_path="$2"
    local path_filter="${3:-}"

    # Include both committed and uncommitted changes since snapshot
    local patch
    if [ -n "$path_filter" ]; then
        patch=$(docker exec "$container_name" sh -c "cd /workspace && git add -A && git diff ccd-snapshot -- '$path_filter'")
    else
        patch=$(docker exec "$container_name" sh -c 'cd /workspace && git add -A && git diff ccd-snapshot')
    fi

    if [ -z "$patch" ]; then
        echo "[ccd] No changes to sync."

        local new_files
        new_files=$(docker exec "$container_name" git -C /workspace ls-files --others --exclude-standard)
        if [ -n "$new_files" ]; then
            echo "[ccd] New files detected (not in patch):"
            echo "$new_files"
            echo "[ccd] Use 'ccd cp <session> <file>' to copy them individually."
        fi
        return 0
    fi

    echo "[ccd] Applying patch to $host_project_path..."
    echo "$patch" | (cd "$host_project_path" && git apply --stat - && echo "$patch" | git apply -)
    echo "[ccd] Sync complete."
}

# Copy a specific file from the container to the host
# Usage: ccd_cp <session_name> <container_path> <host_path>
ccd_cp() {
    local container_name
    container_name=$(ccd_container_name "$1")
    local container_path="$2"
    local host_path="$3"

    # Normalize container path to be under /workspace if relative
    if [[ "$container_path" != /* ]]; then
        container_path="/workspace/$container_path"
    fi

    docker cp "$container_name:$container_path" "$host_path"
    echo "[ccd] Copied $container_path -> $host_path"
}
