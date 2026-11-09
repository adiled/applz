# applz build + install. Run `just` (or `just --list`) to see recipes.

set shell := ["bash", "-uc"]

prefix   := env_var_or_default("PREFIX", "/usr/local")
kernel   := env_var_or_default("HOME", "") / ".applz/kernel/vmlinux"
kata_ver := "3.31.0"
opt      := "ReleaseSafe"

default:
    @just --list

# Build applz and its guest init, then sign applz for Virtualization.framework.
build:
    zig build -Doptimize={{opt}}
    ./scripts/sign.sh

# Run the unit tests (set APPLZ_OCI_SKIP_NET=1 to skip the registry test).
test:
    zig build test

# Fetch the pinned Linux kernel into ~/.applz/kernel (once).
kernel:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -f "{{kernel}}" ]; then echo "kernel present: {{kernel}}"; exit 0; fi
    mkdir -p "$(dirname "{{kernel}}")"
    echo "fetching kata {{kata_ver}} arm64 kernel (streamed, ~40MB kept)..."
    tmp="$(mktemp -d)"
    url="https://github.com/kata-containers/kata-containers/releases/download/{{kata_ver}}/kata-static-{{kata_ver}}-arm64.tar.zst"
    curl -sSL "$url" | zstd -dc | tar -x -C "$tmp" -f - '*vmlinux-*'
    src="$(find "$tmp" -name 'vmlinux-*' ! -name '*debug*' ! -name '*confidential*' ! -name '*gpu*' ! -name '*dragonball*' | head -1)"
    cp "$src" "{{kernel}}"
    rm -rf "$tmp"
    echo "kernel -> {{kernel}}"

# Install applz and applz-init into PREFIX/bin, signed.
install: build
    #!/usr/bin/env bash
    set -euo pipefail
    install -d "{{prefix}}/bin"
    install zig-out/bin/applz zig-out/bin/applz-init "{{prefix}}/bin/"
    ./scripts/sign.sh "{{prefix}}/bin/applz" >/dev/null
    echo "installed -> {{prefix}}/bin"

clean:
    rm -rf zig-out .zig-cache
