#!/bin/bash
# Local build script - runs build-package.sh in Docker containers
# Use this for local development on macOS/Linux

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat << EOF
Usage: $0 [options] <target>

Targets:
    ubuntu              Build Ubuntu packages
    fedora              Build Fedora packages
    all                 Build all packages
    clean               Clean build artifacts

Options:
    --ubuntu-version    Ubuntu version (default: 24.04)
    --fedora-version    Fedora version (default: 43)
    --nvidia-version    NVIDIA driver version (default: auto-detect)
    --no-cache          Build Docker without cache
    -h, --help          Show this help

Examples:
    $0 ubuntu                          # Build for Ubuntu 24.04
    $0 --nvidia-version 580.95.05 all  # Build all with specific version
EOF
    exit 1
}

# Defaults
UBUNTU_VERSION="24.04"
FEDORA_VERSION="43"
NVIDIA_VERSION=""
DOCKER_NO_CACHE=""

# Parse arguments
TARGETS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --ubuntu-version)
            UBUNTU_VERSION="$2"
            shift 2
            ;;
        --fedora-version)
            FEDORA_VERSION="$2"
            shift 2
            ;;
        --nvidia-version)
            NVIDIA_VERSION="$2"
            shift 2
            ;;
        --no-cache)
            DOCKER_NO_CACHE="--no-cache"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            TARGETS+=("$1")
            shift
            ;;
    esac
done

if [ ${#TARGETS[@]} -eq 0 ]; then
    usage
fi

OUTPUT_DIR="$SCRIPT_DIR/output"
mkdir -p "$OUTPUT_DIR"

NVIDIA_VERSION_ARG=""
if [ -n "$NVIDIA_VERSION" ]; then
    NVIDIA_VERSION_ARG="--nvidia-version $NVIDIA_VERSION"
fi

build_ubuntu() {
    local version="${1:-$UBUNTU_VERSION}"
    echo "=== Building Ubuntu $version packages ==="

    docker run --rm \
        --platform linux/arm64 \
        -v "$SCRIPT_DIR:/src:ro" \
        -v "$OUTPUT_DIR:/output" \
        -e OUTPUT_DIR=/output \
        ubuntu:${version} \
        bash -c "
            apt-get update -qq
            apt-get install -y -qq git curl wget ca-certificates build-essential \
                debhelper dpkg-dev fakeroot dkms >/dev/null
            /src/build-package.sh $NVIDIA_VERSION_ARG
        "

    echo "Ubuntu $version build complete"
}

build_fedora() {
    local version="${1:-$FEDORA_VERSION}"
    echo "=== Building Fedora $version packages ==="

    docker run --rm \
        --platform linux/arm64 \
        -v "$SCRIPT_DIR:/src:ro" \
        -v "$OUTPUT_DIR:/output" \
        -e OUTPUT_DIR=/output \
        -e DISTRO_VERSION="$version" \
        fedora:${version} \
        bash -c "
            dnf install -y -q git curl wget ca-certificates rpm-build rpmdevtools \
                gcc gcc-c++ make elfutils-libelf-devel akmods
            /src/build-package.sh $NVIDIA_VERSION_ARG
        "

    echo "Fedora $version build complete"
}

clean_build() {
    echo "=== Cleaning build artifacts ==="
    rm -rf "$OUTPUT_DIR"
    echo "Clean complete"
}

# Execute targets
for target in "${TARGETS[@]}"; do
    case $target in
        ubuntu)
            build_ubuntu
            ;;
        fedora)
            build_fedora
            ;;
        all)
            build_ubuntu
            build_fedora
            ;;
        clean)
            clean_build
            ;;
        *)
            echo "Unknown target: $target"
            usage
            ;;
    esac
done

echo ""
echo "=== Build complete ==="
if [ -d "$OUTPUT_DIR" ]; then
    ls -la "$OUTPUT_DIR"/ 2>/dev/null || echo "No packages built"
fi
