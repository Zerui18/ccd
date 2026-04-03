# ccd

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) inside Docker containers with `--dangerously-skip-permissions`, fully isolated from your host filesystem.

Claude gets its own copy of your project. It can create, delete, and modify anything freely. Nothing touches your real files until you explicitly review and sync changes back.

## Quick start

```bash
# Clone and make available
git clone <repo-url> && cd ccd
export PATH="$PWD:$PATH"

# Run on any project (auto-detects language stack)
ccd run ~/projects/my-app

# Non-interactive with a prompt
ccd run ~/projects/my-app -p "fix all failing tests"
```

## Requirements

- Docker
- Bash 4+
- `git` (on the host, for git-based projects)

## Commands

| Command | Description |
|---------|-------------|
| `ccd run <path> [opts]` | Launch a new session on a project |
| `ccd ls` | List all sessions (running and stopped) |
| `ccd diff <session>` | Show what Claude changed inside the container |
| `ccd sync <session>` | Apply changes back to the host project |
| `ccd cp <session> <file>` | Copy a specific file out of the container |
| `ccd attach <session>` | Reattach to a running session |
| `ccd rm <session>` | Remove a session and its container |
| `ccd clean` | Remove all stopped sessions |
| `ccd build [--stack name]` | Pre-build a Docker image |

### `run` options

```
--stack <name>    Override auto-detected stack (base, node, python, go, rust)
--auth <method>   Force auth method: key or oauth (default: auto)
--name <name>     Custom session name
-p <prompt>       Pass a prompt for non-interactive mode
--print           Print mode (non-interactive)
```

## How it works

### File isolation

Your project is **copied into** the container, not bind-mounted. Claude operates on its own copy with no access to the host filesystem.

- **Git repos**: The full repo is transferred via `git bundle`, preserving history and branches. Uncommitted changes (staged, unstaged, and untracked files) are layered on top.
- **Non-git projects**: Files are copied via `tar`, excluding common build artifacts.

A `ccd-snapshot` git tag is created inside the container at the exact state of your project at copy-in time. All diffs are computed against this tag, so only Claude's changes show up.

### Getting changes back

Changes never sync automatically. You choose what to pull back:

```bash
# See everything Claude changed
ccd diff ccd-myapp-a3f2

# Apply all changes to your host project (as a git patch)
ccd sync ccd-myapp-a3f2

# Apply only changes under src/
ccd sync ccd-myapp-a3f2 --path "src/*"

# Copy a single file out
ccd cp ccd-myapp-a3f2 src/new-file.ts ./src/
```

### Language stacks

ccd auto-detects the project's language and builds a Docker image with the right toolchain:

| Stack | Detected by | Includes |
|-------|------------|----------|
| `node` | `package.json` | Node.js 22, TypeScript, pnpm, yarn |
| `python` | `pyproject.toml`, `uv.lock`, `requirements.txt` | Python 3, uv |
| `go` | `go.mod` | Go 1.23 |
| `rust` | `Cargo.toml` | Rust stable, cargo |
| `base` | (fallback) | Node.js 22 + Claude Code only |

After files are copied in, stack-specific dependency installation runs automatically (`npm ci`, `uv sync`, `go mod download`, etc.) and is committed to the snapshot so it doesn't appear in diffs.

Override with `--stack`:

```bash
ccd run ./my-project --stack python
```

Images are cached and only rebuilt when the corresponding Dockerfile changes.

### Authentication

Two methods, auto-detected:

1. **API key**: If `ANTHROPIC_API_KEY` is set, it's passed to the container as an environment variable.
2. **OAuth**: If `~/.claude` and `~/.claude.json` exist, they're copied into the container.

API key takes priority. Force a specific method with `--auth key` or `--auth oauth`.

### Container security

Every session runs with:

- **Non-root user** (`ccd`, UID 1000)
- **All capabilities dropped** (`--cap-drop=ALL`)
- **No privilege escalation** (`--security-opt=no-new-privileges`)
- **No host filesystem mounts** (files are copied, not mounted)
- **No git credentials** forwarded (no SSH keys or tokens)

## Concurrent sessions

Each `ccd run` creates an independent container. Run as many as you want on different projects simultaneously:

```bash
ccd run ~/projects/frontend -p "add dark mode" &
ccd run ~/projects/api -p "optimize database queries" &
ccd ls  # see both running
```

## Project structure

```
ccd/
├── ccd                        # CLI entry point
├── docker/
│   ├── Dockerfile.base        # Base image: Node.js 22 + Claude Code
│   ├── entrypoint.sh          # Container startup script
│   └── stacks/                # Per-language Dockerfile layers
│       ├── node.Dockerfile
│       ├── python.Dockerfile
│       ├── go.Dockerfile
│       └── rust.Dockerfile
├── lib/
│   ├── sync.sh                # File copy-in, diff, patch-out
│   ├── session.sh             # Session naming and lifecycle
│   └── stack.sh               # Stack detection and image builds
└── config/
    └── stacks.yaml            # Stack definitions (reference)
```
