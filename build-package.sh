#!/bin/bash
# Self-contained package builder for NVIDIA open kernel modules with armsbc patches
# Runs inside a container (Ubuntu or Fedora)
# Usage: ./build-package.sh [options]
#
# This script:
#   1. Detects the distro and version
#   2. Queries for the latest NVIDIA driver version (or uses override)
#   3. Downloads NVIDIA open kernel module source
#   4. Clones and applies armsbc patches
#   5. Builds the appropriate package (.deb or .rpm)

set -e

# ============================================================================
# Configuration
# ============================================================================

FORK_REPO="https://github.com/scottjg/open-gpu-kernel-modules.git"
FORK_BRANCH_BASE="armsbc"
NVIDIA_REPO="https://github.com/NVIDIA/open-gpu-kernel-modules.git"

# Package naming
PACKAGE_RELEASE="2"
PACKAGE_SUFFIX="armsbc"

# Build directories
BUILD_DIR="${BUILD_DIR:-/tmp/nvidia-build}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/output}"

# ============================================================================
# Argument parsing
# ============================================================================

NVIDIA_VERSION=""
SKIP_DOWNLOAD=""
VERBOSE=""

usage() {
    cat << EOF
Usage: $0 [options]

Options:
    --nvidia-version VERSION   Specify NVIDIA driver version (default: auto-detect)
    --output-dir DIR           Output directory for packages (default: ./output)
    --build-dir DIR            Build directory (default: /tmp/nvidia-build)
    --skip-download            Skip downloading source (use existing)
    --verbose                  Verbose output
    -h, --help                 Show this help

Environment variables:
    NVIDIA_VERSION             Same as --nvidia-version
    OUTPUT_DIR                 Same as --output-dir
    BUILD_DIR                  Same as --build-dir

Examples:
    # Auto-detect version and build
    $0

    # Build specific version
    $0 --nvidia-version 580.95.05

    # In GitHub Actions
    docker run --rm -v \$(pwd)/output:/output ubuntu:24.04 ./build-package.sh
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --nvidia-version)
            NVIDIA_VERSION="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --build-dir)
            BUILD_DIR="$2"
            shift 2
            ;;
        --skip-download)
            SKIP_DOWNLOAD="1"
            shift
            ;;
        --verbose)
            VERBOSE="1"
            set -x
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# ============================================================================
# Utility functions
# ============================================================================

log() {
    echo "=== $* ===" >&2
}

error() {
    echo "ERROR: $*" >&2
    exit 1
}

# ============================================================================
# Distro detection
# ============================================================================

detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_ID="$ID"
        DISTRO_VERSION="$VERSION_ID"
        DISTRO_CODENAME="${VERSION_CODENAME:-$VERSION_ID}"
    else
        error "Cannot detect distribution"
    fi

    case "$DISTRO_ID" in
        ubuntu)
            PACKAGE_TYPE="deb"
            ;;
        fedora|rhel|centos|rocky|almalinux)
            PACKAGE_TYPE="rpm"
            ;;
        *)
            error "Unsupported distribution: $DISTRO_ID"
            ;;
    esac

    log "Detected: $DISTRO_ID $DISTRO_VERSION ($DISTRO_CODENAME) - building $PACKAGE_TYPE"
}

# ============================================================================
# Version detection
# ============================================================================

query_nvidia_version() {
    log "Querying NVIDIA driver version"

    case "$DISTRO_ID" in
        ubuntu)
            query_ubuntu_version
            ;;
        fedora)
            query_fedora_version
            ;;
        *)
            error "Version query not implemented for $DISTRO_ID"
            ;;
    esac
}

query_ubuntu_version() {
    # Update package lists
    apt-get update -qq >/dev/null 2>&1

    # Find latest nvidia-dkms-*-open package
    local pkg=$(apt-cache search nvidia-dkms 2>/dev/null | \
                grep -E 'nvidia-dkms-[0-9]+-open ' | \
                sort -t'-' -k3 -n | tail -1 | awk '{print $1}')

    if [ -z "$pkg" ]; then
        error "Could not find nvidia-dkms package in Ubuntu repos"
    fi

    # Get version from package
    NVIDIA_VERSION=$(apt-cache show "$pkg" 2>/dev/null | \
                     grep "^Version:" | head -1 | \
                     awk '{print $2}' | cut -d'-' -f1)

    if [ -z "$NVIDIA_VERSION" ]; then
        error "Could not determine NVIDIA version from $pkg"
    fi

    log "Found NVIDIA version: $NVIDIA_VERSION (from $pkg)"
}

query_fedora_version() {
    # Enable RPM Fusion repos if not already present
    if ! dnf repolist 2>/dev/null | grep -q rpmfusion; then
        log "Enabling RPM Fusion repositories"
        dnf install -y \
            "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-${DISTRO_VERSION}.noarch.rpm" \
            "https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${DISTRO_VERSION}.noarch.rpm" \
            2>/dev/null || true
    fi

    dnf makecache -q 2>/dev/null || true

    # Try to find akmod-nvidia (open or proprietary)
    local version=""
    for pkg in akmod-nvidia-open akmod-nvidia; do
        version=$(dnf info "$pkg" 2>/dev/null | \
                  grep "^Version" | awk '{print $3}' | head -1)
        if [ -n "$version" ]; then
            NVIDIA_VERSION="$version"
            log "Found NVIDIA version: $NVIDIA_VERSION (from $pkg)"
            return
        fi
    done

    if [ -z "$NVIDIA_VERSION" ]; then
        error "Could not find NVIDIA driver in Fedora/RPM Fusion repos. Please specify --nvidia-version"
    fi
}

# ============================================================================
# Source preparation
# ============================================================================

download_nvidia_source() {
    log "Downloading NVIDIA open kernel modules v${NVIDIA_VERSION}"

    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    # Clone NVIDIA repo at specific tag
    if [ ! -d "nvidia-source" ]; then
        git clone --depth 1 --branch "${NVIDIA_VERSION}" \
            "$NVIDIA_REPO" nvidia-source
    fi

    SOURCE_DIR="$BUILD_DIR/nvidia-source"
}

generate_patches() {
    cd "$BUILD_DIR"

    # Determine the fork branch to use based on major version
    local nvidia_major="${NVIDIA_VERSION%%.*}"
    local versioned_branch="${FORK_BRANCH_BASE}-${nvidia_major}"
    local fork_branch=""

    # Clone fork as bare repo to extract patches
    if [ ! -d "fork.git" ]; then
        git clone --bare "$FORK_REPO" fork.git
    fi

    cd fork.git

    # Try versioned branch first (e.g., armsbc-590), fall back to base branch (armsbc)
    if git fetch origin "$versioned_branch" 2>/dev/null; then
        fork_branch="$versioned_branch"
        log "Using versioned branch: $fork_branch"
    elif git fetch origin "$FORK_BRANCH_BASE" 2>/dev/null; then
        fork_branch="$FORK_BRANCH_BASE"
        log "Versioned branch $versioned_branch not found, using fallback branch: $fork_branch"
    else
        error "Could not find branch $versioned_branch or $FORK_BRANCH_BASE in $FORK_REPO"
    fi

    log "Generating patches from $fork_branch"

    # Find merge base between the fork branch and main on our repo
    git fetch origin main 2>/dev/null || error "Could not fetch main branch from $FORK_REPO"
    local merge_base=$(git merge-base "$fork_branch" "main" 2>/dev/null)

    if [ -z "$merge_base" ]; then
        error "Could not find merge base between $fork_branch and main"
    fi

    # Generate patches
    mkdir -p "$BUILD_DIR/patches"
    git format-patch -o "$BUILD_DIR/patches" "${merge_base}..${fork_branch}"

    PATCHES_DIR="$BUILD_DIR/patches"
    log "Generated $(ls -1 "$PATCHES_DIR"/*.patch 2>/dev/null | wc -l) patches"
}

apply_patches() {
    log "Applying armsbc patches"

    cd "$SOURCE_DIR"

    for patch in "$PATCHES_DIR"/*.patch; do
        if [ -f "$patch" ]; then
            echo "Applying $(basename "$patch")..."
            git apply --check "$patch" 2>/dev/null || true
            git apply "$patch" || {
                echo "Warning: patch may have partially applied: $(basename "$patch")"
            }
        fi
    done
}

# ============================================================================
# Package building
# ============================================================================

build_deb_package() {
    log "Building Ubuntu package"

    local nvidia_major="${NVIDIA_VERSION%%.*}"
    local dkms_name="nvidia-open-${PACKAGE_SUFFIX}"
    local package_name="nvidia-dkms-${nvidia_major}-open-${PACKAGE_SUFFIX}"

    local pkg_dir="$BUILD_DIR/package"
    local dkms_src="$pkg_dir/usr/src/${dkms_name}-${NVIDIA_VERSION}"

    # Create package structure
    rm -rf "$pkg_dir"
    mkdir -p "$dkms_src"
    mkdir -p "$pkg_dir/DEBIAN"
    mkdir -p "$pkg_dir/etc/modprobe.d"

    # Copy source
    cp -a "$SOURCE_DIR"/* "$dkms_src/"

    # Create dkms.conf
    cat > "$dkms_src/dkms.conf" << EOF
PACKAGE_NAME="${dkms_name}"
PACKAGE_VERSION="${NVIDIA_VERSION}"
AUTOINSTALL="yes"
BUILD_EXCLUSIVE_ARCH="aarch64"
MAKE[0]="make -j\$(nproc) modules KERNELRELEASE= KERNEL_UNAME=\$kernelver"
CLEAN="make clean"

BUILT_MODULE_NAME[0]="nvidia"
BUILT_MODULE_LOCATION[0]="kernel-open"
DEST_MODULE_LOCATION[0]="/updates/dkms"

BUILT_MODULE_NAME[1]="nvidia-modeset"
BUILT_MODULE_LOCATION[1]="kernel-open"
DEST_MODULE_LOCATION[1]="/updates/dkms"

BUILT_MODULE_NAME[2]="nvidia-drm"
BUILT_MODULE_LOCATION[2]="kernel-open"
DEST_MODULE_LOCATION[2]="/updates/dkms"

BUILT_MODULE_NAME[3]="nvidia-uvm"
BUILT_MODULE_LOCATION[3]="kernel-open"
DEST_MODULE_LOCATION[3]="/updates/dkms"

BUILT_MODULE_NAME[4]="nvidia-peermem"
BUILT_MODULE_LOCATION[4]="kernel-open"
DEST_MODULE_LOCATION[4]="/updates/dkms"
EOF

    # Create modprobe blacklist
    cat > "$pkg_dir/etc/modprobe.d/nvidia-${PACKAGE_SUFFIX}-blacklist.conf" << 'EOF'
blacklist nouveau
options nouveau modeset=0
EOF

    # Create control file
    generate_deb_control > "$pkg_dir/DEBIAN/control"

    # Create maintainer scripts
    generate_deb_postinst > "$pkg_dir/DEBIAN/postinst"
    generate_deb_prerm > "$pkg_dir/DEBIAN/prerm"
    chmod 755 "$pkg_dir/DEBIAN/postinst" "$pkg_dir/DEBIAN/prerm"

    # Build package
    mkdir -p "$OUTPUT_DIR"
    dpkg-deb --build --root-owner-group "$pkg_dir" \
        "$OUTPUT_DIR/${package_name}_${NVIDIA_VERSION}-${PACKAGE_RELEASE}_arm64.deb"

    log "Built: ${package_name}_${NVIDIA_VERSION}-${PACKAGE_RELEASE}_arm64.deb"
}

generate_deb_control() {
    local nvidia_major="${NVIDIA_VERSION%%.*}"

    cat << EOF
Package: nvidia-dkms-${nvidia_major}-open-${PACKAGE_SUFFIX}
Version: ${NVIDIA_VERSION}-${PACKAGE_RELEASE}
Architecture: arm64
Multi-Arch: foreign
Maintainer: Scott J. Goldman <scottjg@umich.edu>
Depends: dkms, nvidia-kernel-common-${nvidia_major} (>= ${NVIDIA_VERSION}), nvidia-kernel-common-${nvidia_major} (<< ${NVIDIA_VERSION}.99)
Provides: nvidia-dkms-kernel, nvidia-dkms-${nvidia_major}-open (= ${NVIDIA_VERSION}-${PACKAGE_RELEASE})
Conflicts: nvidia-dkms-kernel, nvidia-dkms-${nvidia_major}-open
Replaces: nvidia-dkms-kernel, nvidia-dkms-${nvidia_major}-open
Section: restricted/libs
Priority: optional
Homepage: https://github.com/NVIDIA/open-gpu-kernel-modules
Description: NVIDIA DKMS package (open kernel module) with patches for ARM SBC platforms
 This package builds the open NVIDIA kernel module using DKMS.
 Patched for RK3588 and similar ARM platforms with non-cache-coherent PCIe.
 .
 Patches from: https://github.com/scottjg/open-gpu-kernel-modules
EOF
}

generate_deb_postinst() {
    local dkms_name="nvidia-open-${PACKAGE_SUFFIX}"
    cat << EOF
#!/bin/bash
set -e

DKMS_NAME="${dkms_name}"
DKMS_VERSION="${NVIDIA_VERSION}"

if [ "\$1" = "configure" ]; then
    if [ -x /usr/sbin/dkms ]; then
        dkms add -m "\$DKMS_NAME" -v "\$DKMS_VERSION" || true
        dkms build -m "\$DKMS_NAME" -v "\$DKMS_VERSION" || true
        dkms install -m "\$DKMS_NAME" -v "\$DKMS_VERSION" || true
    fi
fi

exit 0
EOF
}

generate_deb_prerm() {
    local dkms_name="nvidia-open-${PACKAGE_SUFFIX}"
    cat << EOF
#!/bin/bash
set -e

DKMS_NAME="${dkms_name}"
DKMS_VERSION="${NVIDIA_VERSION}"

if [ "\$1" = "remove" ] || [ "\$1" = "purge" ]; then
    if [ -x /usr/sbin/dkms ]; then
        dkms remove -m "\$DKMS_NAME" -v "\$DKMS_VERSION" --all || true
    fi
fi

exit 0
EOF
}

build_rpm_package() {
    log "Building Fedora RPM package"

    local kmod_name="nvidia-${PACKAGE_SUFFIX}"
    local package_name="akmod-${kmod_name}"

    local rpm_build="$BUILD_DIR/rpmbuild"
    mkdir -p "$rpm_build"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

    # Create source tarball
    cd "$BUILD_DIR"
    local tarball_name="${kmod_name}-${NVIDIA_VERSION}"
    rm -rf "$tarball_name"
    cp -a nvidia-source "$tarball_name"
    tar czf "$rpm_build/SOURCES/${tarball_name}.tar.gz" "$tarball_name"

    # Generate spec file
    generate_rpm_spec > "$rpm_build/SPECS/${package_name}.spec"

    # Build RPM
    rpmbuild \
        --define "_topdir $rpm_build" \
        --define "dist .fc${DISTRO_VERSION}" \
        -ba "$rpm_build/SPECS/${package_name}.spec"

    # Copy output
    mkdir -p "$OUTPUT_DIR"
    cp -v "$rpm_build/RPMS"/*/*.rpm "$OUTPUT_DIR/" 2>/dev/null || true
    cp -v "$rpm_build/SRPMS"/*.rpm "$OUTPUT_DIR/" 2>/dev/null || true

    log "Built RPM packages in $OUTPUT_DIR"
}

generate_rpm_spec() {
    local kmod_name="nvidia-${PACKAGE_SUFFIX}"
    cat << EOF
%global kmod_name ${kmod_name}
%global debug_package %{nil}
%global nvidia_version ${NVIDIA_VERSION}
%global package_release ${PACKAGE_RELEASE}

Name:           akmod-%{kmod_name}
Epoch:          3
Version:        %{nvidia_version}
Release:        %{package_release}%{?dist}
Summary:        NVIDIA kernel module with ARM SBC patches (akmod)

License:        NVIDIA
URL:            https://github.com/NVIDIA/open-gpu-kernel-modules
Source0:        %{kmod_name}-%{nvidia_version}.tar.gz

BuildRequires:  elfutils-libelf-devel
BuildRequires:  gcc
BuildRequires:  gcc-c++
BuildRequires:  make

Requires:       akmods
Requires:       kernel-devel
Requires:       nvidia-kmod-common >= 3:%{nvidia_version}
Requires(post): akmods
Requires(preun): akmods

# Provide akmod-nvidia so this is a drop-in replacement
Provides:       akmod-nvidia = 3:%{nvidia_version}
Provides:       akmod-nvidia-open = 3:%{nvidia_version}
Conflicts:      akmod-nvidia
Conflicts:      akmod-nvidia-open
Obsoletes:      akmod-nvidia < 3:%{nvidia_version}
Obsoletes:      akmod-nvidia-open < 3:%{nvidia_version}

# Provide nvidia-kmod so userspace packages can be installed
# (normally provided by kmod-nvidia which is built from akmod-nvidia)
Provides:       nvidia-kmod = 3:%{nvidia_version}
Provides:       nvidia-kmod(aarch64) = 3:%{nvidia_version}
Provides:       kmod-nvidia = 3:%{nvidia_version}

# Conflict with the real kmod-nvidia to prevent both from being installed
Conflicts:      kmod-nvidia

ExclusiveArch:  aarch64

%description
NVIDIA open kernel module source with ARM SBC DMA cache coherency patches.
Patches from: https://github.com/scottjg/open-gpu-kernel-modules

%prep
%setup -q -n %{kmod_name}-%{nvidia_version}

%build
echo "Source prepared for akmod build"

%install
mkdir -p %{buildroot}%{_usrsrc}/akmods/%{kmod_name}-%{nvidia_version}
cp -a * %{buildroot}%{_usrsrc}/akmods/%{kmod_name}-%{nvidia_version}/

mkdir -p %{buildroot}%{_sysconfdir}/modprobe.d
cat > %{buildroot}%{_sysconfdir}/modprobe.d/%{kmod_name}.conf << 'MODPROBE'
blacklist nouveau
options nouveau modeset=0
MODPROBE

cat > %{buildroot}%{_usrsrc}/akmods/%{kmod_name}-%{nvidia_version}/akmods-build.sh << 'BUILDSCRIPT'
#!/bin/bash
set -e
KERNEL_VERSION="\${1:-\$(uname -r)}"
cd "\$(dirname "\$0")"
make -j\$(nproc) modules KERNEL_UNAME="\$KERNEL_VERSION"
DEST="/lib/modules/\$KERNEL_VERSION/extra/%{kmod_name}"
mkdir -p "\$DEST"
install -m 644 kernel-open/*.ko "\$DEST/"
depmod -a "\$KERNEL_VERSION"
BUILDSCRIPT
chmod +x %{buildroot}%{_usrsrc}/akmods/%{kmod_name}-%{nvidia_version}/akmods-build.sh

%post
%{_usrsrc}/akmods/%{kmod_name}-%{nvidia_version}/akmods-build.sh "\$(uname -r)" || :

%preun
if [ \$1 -eq 0 ]; then
    rm -rf /lib/modules/*/extra/%{kmod_name} 2>/dev/null || :
fi

%files
%license COPYING
%doc README.md
%{_usrsrc}/akmods/%{kmod_name}-%{nvidia_version}/
%config(noreplace) %{_sysconfdir}/modprobe.d/%{kmod_name}.conf

%changelog
* $(date "+%a %b %d %Y") Package Builder <builder@example.com> - %{nvidia_version}-%{package_release}
- Initial package with armsbc/ARM DMA cache coherency patches
EOF
}

# ============================================================================
# Main
# ============================================================================

main() {
    log "NVIDIA Open Kernel Modules Builder (armsbc patched)"

    # Detect distribution
    detect_distro

    # Get NVIDIA version
    if [ -z "$NVIDIA_VERSION" ]; then
        query_nvidia_version
    else
        log "Using specified NVIDIA version: $NVIDIA_VERSION"
    fi

    # Prepare source
    if [ -z "$SKIP_DOWNLOAD" ]; then
        download_nvidia_source
        generate_patches
        apply_patches
    else
        SOURCE_DIR="$BUILD_DIR/nvidia-source"
        PATCHES_DIR="$BUILD_DIR/patches"
        if [ ! -d "$SOURCE_DIR" ]; then
            error "Source not found at $SOURCE_DIR (--skip-download requires existing source)"
        fi
    fi

    # Build package
    case "$PACKAGE_TYPE" in
        deb)
            build_deb_package
            ;;
        rpm)
            build_rpm_package
            ;;
    esac

    log "Build complete!"
    ls -la "$OUTPUT_DIR"/*.{deb,rpm} 2>/dev/null || true
}

main "$@"

