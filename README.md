# NVIDIA Open Kernel Modules with armsbc Patches

Build DKMS packages for NVIDIA GPUs on ARM platforms like the RK3588 that lack DMA cache coherency.

## Patches

This project applies patches from [scottjg/open-gpu-kernel-modules](https://github.com/scottjg/open-gpu-kernel-modules) to the official NVIDIA open kernel modules. These patches are written almost entirely by @mariobalanica (I just rebased to the latest drivers and packaged for slightly easier usage). These packages are meant to replace the Fedora and Ubuntu distribution packages (not the mainline drivers from NVIDIA).

My goal with these packages was to provide a relatively simple way to setup an AI inference server with a low-cost ARM single board computer, and a spare graphics card I had lying around. These drivers have been reported to work for actual gaming with a 3d accelerated desktop on RK3855 platforms, though I have not tested them for this purpose. In my case, I have tested these drivers with an Orange Pi 5 Plus and an NVIDIA RTX 4090. I was inspired by [@geerlingguy's blog post](https://www.jeffgeerling.com/blog/2025/nvidia-graphics-cards-work-on-pi-5-and-rockchip) on the subject.

Please be advised that I am just packaging these existing patches. It's unlikely that I will provide meaningful support or fixes for them, other than keeping them up to date and providing package repos for installation. 

## Requirements

- **Ubuntu** 24.04, 25.10 (`.deb` with DKMS)
- **Fedora** 43, rawhide (`.rpm` with akmod)

The patches were mostly tested on the RK3588 platform (like the Orange Pi 5 Plus), using a kernel with a 4k page size. The default devicetree memory maps on these platforms are not compatible out of the box with these drivers. It is recommended you boot with a [UEFI EDK2 firmware](https://github.com/edk2-porting/edk2-rk3588) that was ported to these platforms, which has been configured with an updated device tree, and is capable of booting mainline arm linux distributions.

## Quick Start

## Installation

### Ubuntu

```bash
# Install the package
sudo dpkg -i nvidia-dkms-580-open-armsbc_*.deb

# Install NVIDIA userspace (from Ubuntu repos)
sudo apt install nvidia-headless-580-open nvidia-utils-580
```

### Fedora

```bash
# Install the package
sudo dnf install ./akmod-nvidia-armsbc-*.rpm

# Install NVIDIA userspace (from RPM Fusion)
sudo dnf install xorg-x11-drv-nvidia-cuda
```

### Local Build (requires Docker)

```bash
# Build for your preferred distro
./build.sh ubuntu
./build.sh fedora

# Build all
./build.sh all

# Specify NVIDIA driver version
./build.sh --nvidia-version 580.95.05 ubuntu
```

Packages are output to `./output/`.

## License

The build scripts in this repository are MIT licensed.
The NVIDIA kernel modules are subject to NVIDIA's license terms.
