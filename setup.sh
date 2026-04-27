#!/usr/bin/env bash
#
# harbor-workbench — one-shot install of the complete toolchain.
#
# Installs (idempotent, safe to re-run):
#   - System packages + Docker (Linux only)
#   - uv
#   - gh CLI
#   - Claude Code
#   - opencode
#   - Harbor (from patched branch; see HARBOR_REF below)
#   - harbor-workbench itself
#
# Usage — vetted install (default):
#   curl -fsSL https://raw.githubusercontent.com/Proximal-Labs/hbw-installer/stable/setup.sh | bash
#
# Usage — bleeding edge:
#   curl -fsSL https://raw.githubusercontent.com/Proximal-Labs/hbw-installer/main/setup.sh | WORKBENCH_REF=main bash
#
# The public Proximal-Labs/hbw-installer repo is a branch-for-branch mirror of
# this file (see .github/workflows/sync-installer.yml). `harbor-workbench setup`
# is a thin wrapper around the `stable` curl line above.
#
# Env overrides (all optional):
#   HARBOR_REF       harbor branch/tag/commit    (default: release/v0.4.0-patched)
#   WORKBENCH_REF    harbor-workbench ref        (default: stable)
#   PYTHON_VERSION   python for uv tools         (default: 3.13)
#
# Requires SSH access to Proximal-Labs repos on GitHub.
#
set -euo pipefail

HARBOR_REF="${HARBOR_REF:-release/v0.4.0-patched}"
WORKBENCH_REF="${WORKBENCH_REF:-stable}"
PYTHON_VERSION="${PYTHON_VERSION:-3.13}"

HARBOR_SPEC="harbor[modal] @ git+ssh://git@github.com/Proximal-Labs/harbor.git@${HARBOR_REF}"
WORKBENCH_SPEC="git+ssh://git@github.com/Proximal-Labs/harbor-workbench.git@${WORKBENCH_REF}"

echo "============================================"
echo " harbor-workbench — Toolchain Install"
echo "============================================"
echo "  Harbor ref:          $HARBOR_REF"
echo "  harbor-workbench ref: $WORKBENCH_REF"
echo "  Python:               $PYTHON_VERSION"
echo ""

# ─── Detect OS ───────────────────────────────────────────────────────────────
IS_MAC=false
IS_LINUX=false
case "$(uname)" in
    Darwin) IS_MAC=true ;;
    Linux)  IS_LINUX=true ;;
    *)      echo "ERROR: Unsupported OS: $(uname)"; exit 1 ;;
esac

# ─── System packages (Linux only) ───────────────────────────────────────────
if $IS_LINUX; then
    echo ">>> Installing system packages..."
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        docker.io \
        docker-compose-v2 \
        git \
        tmux
    echo ""

    if ! groups | grep -q docker; then
        echo ">>> Adding $USER to docker group..."
        sudo usermod -aG docker "$USER"
    fi
    sudo systemctl start docker 2>/dev/null || true
fi

# ─── docker buildx (Linux only — macOS gets it via Docker Desktop) ──────────
# Ubuntu's ``docker.io`` package doesn't ship buildx; Docker's own
# ``docker-buildx-plugin`` lives in a separate apt repo we'd rather not
# add. Instead, drop the upstream binary as a user-level CLI plugin —
# ``docker buildx`` discovers it automatically.
if $IS_LINUX && ! docker buildx version &>/dev/null; then
    echo ">>> Installing docker buildx CLI plugin..."
    # Follow GitHub's /releases/latest redirect to get the tag — no API
    # call, no version pinning.
    buildx_tag="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
        https://github.com/docker/buildx/releases/latest \
        | sed 's|.*/tag/||')"
    case "$(uname -m)" in
        x86_64|amd64) buildx_arch=amd64 ;;
        aarch64|arm64) buildx_arch=arm64 ;;
        *) buildx_arch="" ;;
    esac
    if [ -n "$buildx_tag" ] && [ -n "$buildx_arch" ]; then
        mkdir -p "$HOME/.docker/cli-plugins"
        curl -fsSL -o "$HOME/.docker/cli-plugins/docker-buildx" \
            "https://github.com/docker/buildx/releases/download/${buildx_tag}/buildx-${buildx_tag}.linux-${buildx_arch}"
        chmod +x "$HOME/.docker/cli-plugins/docker-buildx"
        echo "  Installed: $HOME/.docker/cli-plugins/docker-buildx ($buildx_tag)"
    else
        echo "  [WARN] couldn't auto-install buildx; grab it manually:"
        echo "         https://github.com/docker/buildx/releases/latest"
    fi
    echo ""
fi

# ─── uv ──────────────────────────────────────────────────────────────────────
if ! command -v uv &>/dev/null; then
    echo ">>> Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    echo ""
else
    echo ">>> uv already installed: $(uv --version)"
fi

# ─── gh CLI (for auto-creating repos on push) ───────────────────────────────
if ! command -v gh &>/dev/null; then
    echo ">>> Installing gh CLI..."
    if $IS_MAC; then
        if command -v brew &>/dev/null; then
            brew install gh
        else
            echo "  [SKIP] Install Homebrew first, then: brew install gh"
        fi
    elif $IS_LINUX; then
        (type -p wget >/dev/null || sudo apt-get install -y wget) \
            && sudo mkdir -p -m 755 /etc/apt/keyrings \
            && out=$(mktemp) && wget -nv -O"$out" https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            && cat "$out" | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
            && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
            && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
            && sudo apt-get update \
            && sudo apt-get install -y gh
    fi
    if command -v gh &>/dev/null; then
        echo "  Installed. Run 'gh auth login' to authenticate."
    fi
    echo ""
else
    echo ">>> gh CLI already installed: $(gh --version 2>&1 | head -1)"
fi

# ─── Claude Code ─────────────────────────────────────────────────────────────
if ! command -v claude &>/dev/null; then
    echo ">>> Installing Claude Code..."
    curl -fsSL https://claude.ai/install.sh | bash
    export PATH="$HOME/.local/bin:$PATH"
    echo ""
else
    echo ">>> Claude Code already installed: $(claude --version 2>&1 | head -1)"
fi

# ─── opencode (used by QA pipeline) ─────────────────────────────────────────
if ! command -v opencode &>/dev/null && [ ! -f "$HOME/.opencode/bin/opencode" ]; then
    echo ">>> Installing opencode..."
    curl -fsSL https://opencode.ai/install | bash
    export PATH="$HOME/.opencode/bin:$PATH"
    echo ""
else
    echo ">>> opencode already installed"
fi

# ─── crane (used by `harbor-workbench datasets push/pull`) ──────────────────
# go-containerregistry's `crane` lets us append / pull / retag OCI images at
# the registry level, without materializing the dataset locally. That's the
# whole point of the `datasets` subcommand — push a new artifact into a
# dataset tag in O(new-file), not O(dataset).
if ! command -v crane &>/dev/null; then
    echo ">>> Installing crane..."
    if $IS_MAC; then
        if command -v brew &>/dev/null; then
            brew install crane
        else
            echo "  [SKIP] Install Homebrew first, then: brew install crane"
        fi
    elif $IS_LINUX; then
        # Fetch the official release tarball; /usr/local/bin is on PATH
        # by default on every distro we care about.
        arch="$(uname -m)"
        case "$arch" in
            x86_64|amd64) crane_arch=x86_64 ;;
            aarch64|arm64) crane_arch=arm64 ;;
            *) echo "  [SKIP] Unsupported arch for crane auto-install: $arch"; crane_arch="" ;;
        esac
        if [ -n "$crane_arch" ]; then
            tmpdir="$(mktemp -d)"
            url="https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_Linux_${crane_arch}.tar.gz"
            curl -fsSL "$url" | tar -xz -C "$tmpdir" crane
            sudo install -m 0755 "$tmpdir/crane" /usr/local/bin/crane
            rm -rf "$tmpdir"
        fi
    fi
    command -v crane &>/dev/null && echo "  Installed: $(crane version 2>&1 | head -1)"
    echo ""
else
    echo ">>> crane already installed: $(crane version 2>&1 | head -1)"
fi

# ─── Harbor (patched branch) ─────────────────────────────────────────────────
echo ""
echo ">>> Installing Harbor ($HARBOR_REF)..."
uv tool install "$HARBOR_SPEC" --python "$PYTHON_VERSION" --force
echo ""

# ─── harbor-workbench ───────────────────────────────────────────────────────
echo ">>> Installing harbor-workbench ($WORKBENCH_REF)..."
uv tool install "$WORKBENCH_SPEC" --python "$PYTHON_VERSION" --force
echo ""

# ─── GCP service account for image uploads ─────────────────────────────────
# The harbor-workbench package ships a vendored service-account key so
# every collaborator can 'harbor-workbench upload' out of the box.
# This step copies it to ~/.config/harbor-workbench/gcp-sa.json and runs
# 'gcloud auth activate-service-account' + 'configure-docker'. It's
# idempotent; safe to re-run. If gcloud isn't installed yet, the key
# is still dropped on disk and upload subprocesses pick it up via
# GOOGLE_APPLICATION_CREDENTIALS (direct-API paths work; docker push
# will fail until gcloud is installed and 'harbor-workbench auth' is
# re-run).
if command -v harbor-workbench &>/dev/null; then
    echo ">>> Provisioning GCP auth..."
    harbor-workbench auth || echo "  [WARN] harbor-workbench auth failed; re-run manually once gcloud is installed."
    echo ""
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo "============================================"
echo " Setup Complete"
echo "============================================"
echo ""
echo "  Installed:"
command -v docker &>/dev/null            && echo "    ✓ Docker            $(docker --version 2>&1 | head -c 40)"
docker buildx version &>/dev/null        && echo "    ✓ docker buildx     $(docker buildx version 2>&1 | head -1 | head -c 60)"
command -v uv &>/dev/null                && echo "    ✓ uv                $(uv --version 2>&1)"
command -v gh &>/dev/null                && echo "    ✓ gh CLI            $(gh --version 2>&1 | head -1)"
command -v claude &>/dev/null            && echo "    ✓ Claude Code       $(claude --version 2>&1 | head -1)"
(command -v opencode &>/dev/null || [ -f "$HOME/.opencode/bin/opencode" ]) \
                                         && echo "    ✓ opencode"
command -v crane &>/dev/null             && echo "    ✓ crane             $(crane version 2>&1 | head -1)"
command -v harbor &>/dev/null            && echo "    ✓ Harbor            $(harbor --version 2>&1)"
command -v harbor-workbench &>/dev/null  && echo "    ✓ harbor-workbench  $(harbor-workbench --version 2>&1 || true)"
echo ""
echo "  Next steps:"
if ! docker info &>/dev/null; then
    if $IS_MAC; then
        if ! command -v docker &>/dev/null; then
            echo "    - Install Docker Desktop:  https://docs.docker.com/desktop/install/mac-install/"
        else
            echo "    - Start Docker Desktop (currently not reachable)"
        fi
    elif $IS_LINUX; then
        echo "    - Reopen your terminal (or run 'newgrp docker') so docker group membership takes effect"
    fi
fi
echo "    - Run 'gh auth login' if not already authenticated"
echo "    - Create a workspace:  harbor-workbench init my-bench --workspace"
echo "    - Add API keys:        cd my-bench && cp .env.example .env"
echo ""
