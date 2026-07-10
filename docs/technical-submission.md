# 在 hvisor x86_64 QEMU 上运行 Asterinas

本文档介绍如何在 x86_64 QEMU/KVM 环境中启动 hvisor，并在非 root zone（zone1）中运行 Asterinas。完成后，zone0 中的 hvisor-tool 可以启动 Asterinas，并通过 virtio-console 进入 Asterinas shell。

后续步骤会完成两类验证：一是启动并进入 Asterinas shell；二是在 zone1 中运行系统能力验证，覆盖多核、块设备、系统调用、用户态程序、内存、IPC、时间和 IO 路径。

适用宿主为 x86_64 Linux，要求 QEMU/KVM 可用、`/dev/kvm` 可访问、当前用户可执行需要的 `sudo` 操作，并且宿主与 zone0 rootfs 中可使用伪终端 `/dev/pts`。在 WSL 或容器中运行时，KVM、loop mount、内核模块构建和 `/dev/pts` 访问可能受宿主权限限制，需要先确认这些基础能力。

开始前，克隆复现配置仓库，并把仓库根目录作为后续步骤的工作目录：

```bash
git clone https://github.com/xingmin1/hvisor-asterinas-repro.git
cd hvisor-asterinas-repro
```

无法访问 GitHub 时，可以改用 GitLink 镜像：

```bash
git clone https://gitlink.org.cn/xmin/hvisor-asterinas-repro.git
cd hvisor-asterinas-repro
```

该仓库包含 `flake.nix`、`flake.lock`、`toolchains/` 和三份运行配置。`zone1_asterinas.json` 用于启动可交互的 Asterinas zone1；`zone1_asterinas_boot_hello.json` 用于最小启动检查；`virtio_cfg_asterinas.json` 用于 hvisor-tool 创建 virtio-console 和两个 virtio-blk 设备。Nix flake 路线使用仓库中的 flake 和 Rust 工具链声明；Ubuntu / 非 Nix 路线只使用三份运行配置。后续命令会把 hvisor 源码克隆到 `ref/hvisor`，把 Asterinas 源码克隆到 `ref/asterinas`。

本文档使用两个公开 fork。hvisor fork 基于 `syswonder/hvisor` 的 `dev` 分支，适配分支为 `migration/hvisor-asterinas-x86`，包含 Asterinas 启动所需的 x86_64 虚拟化适配；Asterinas fork 基于 `asterinas/asterinas`，适配分支同样为 `migration/hvisor-asterinas-x86`，包含 hvisor 环境下的启动、virtio-mmio 和测试适配。后续命令固定到以下分支和 commit：

- hvisor：GitHub 仓库为 `https://github.com/xingmin1/hvisor.git`，GitLink 镜像为 `https://gitlink.org.cn/xmin/hvisor.git`，分支 `migration/hvisor-asterinas-x86`，commit `add78abf74dfa298090967e0ee75b873e6d8fb26`
- Asterinas：GitHub 仓库为 `https://github.com/xingmin1/asterinas-in-hvisor.git`，GitLink 镜像为 `https://gitlink.org.cn/xmin/asterinas-in-hvisor.git`，分支 `migration/hvisor-asterinas-x86`，commit `1f325b3da2e97f7e00e18d37ebec8c9249b7eccb`

如果需要从 GitLink 下载源码，请在两条路线的“准备源码工作区”步骤中使用以下地址：

```bash
export HVISOR_REMOTE=https://gitlink.org.cn/xmin/hvisor.git
export ASTERINAS_REMOTE=https://gitlink.org.cn/xmin/asterinas-in-hvisor.git
```

本文档分为 Nix 和非 Nix 两种环境构建、运行，但主要维护 Nix 环境的，提交前已多次在下面的 Nix 环境下进行了验证。

## 一、Nix flake 环境运行

本路线直接在文首克隆的复现配置仓库根目录执行。仓库已经包含 flake、Rust 工具链声明和运行配置，不需要另行创建 Git 工作树或复制配置文件。

### 在 Ubuntu/Debian 上安装 Nix 并启用 flakes

如果当前 Ubuntu、Debian 或其衍生系统尚未安装 Nix，可以先安装 Nix，再继续本章。以下多用户 daemon 安装方式要求系统使用 systemd、未启用 SELinux，并且当前用户能够执行 `sudo`：

```bash
sudo apt-get update
sudo apt-get install -y curl xz-utils
curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install | \
  sh -s -- --daemon
```

安装完成后重新打开终端。随后在当前用户的 Nix 配置中启用 `nix-command` 和 `flakes`：

```bash
nix_conf="${XDG_CONFIG_HOME:-$HOME/.config}/nix/nix.conf"
mkdir -p "$(dirname "$nix_conf")"
touch "$nix_conf"
grep -qxF 'extra-experimental-features = nix-command flakes' "$nix_conf" || \
  printf '%s\n' 'extra-experimental-features = nix-command flakes' >> "$nix_conf"

nix --version
nix flake --help >/dev/null
nix store info
```

确认上述命令成功，并且 `nix store info` 的输出包含 `Store URL: daemon`。随后回到复现配置仓库根目录，继续执行下面的 Nix flake 流程。

### 1. 准备源码工作区

执行以下命令下载两个源码仓库，并切换到本文固定使用的 commit。Rust 工具链声明来自这两个 fork 中各自的 `rust-toolchain.toml`。

```bash
hvisor_remote=${HVISOR_REMOTE:-https://github.com/xingmin1/hvisor.git}
asterinas_remote=${ASTERINAS_REMOTE:-https://github.com/xingmin1/asterinas-in-hvisor.git}
hvisor_branch=migration/hvisor-asterinas-x86
asterinas_branch=migration/hvisor-asterinas-x86
hvisor_commit=add78abf74dfa298090967e0ee75b873e6d8fb26
asterinas_commit=1f325b3da2e97f7e00e18d37ebec8c9249b7eccb

mkdir -p ref
if [ ! -d ref/hvisor/.git ]; then
  git clone "$hvisor_remote" ref/hvisor
fi
if [ ! -d ref/asterinas/.git ]; then
  git clone "$asterinas_remote" ref/asterinas
fi

git -C ref/hvisor fetch "$hvisor_remote" "$hvisor_branch"
git -C ref/hvisor fetch "$hvisor_remote" "$hvisor_commit"
git -C ref/hvisor checkout --detach "$hvisor_commit"
git -C ref/asterinas fetch "$asterinas_remote" "$asterinas_branch"
git -C ref/asterinas fetch "$asterinas_remote" "$asterinas_commit"
git -C ref/asterinas checkout --detach "$asterinas_commit"

git -C ref/hvisor rev-parse HEAD
git -C ref/asterinas rev-parse HEAD
git -C ref/hvisor branch -r --contains HEAD | grep "$hvisor_branch"
git -C ref/asterinas branch -r --contains HEAD | grep "$asterinas_branch"
```

### 2. 进入 hvisor 开发环境

这一步使用根目录 `flake.nix`。`.#hvisor` shell 只用于 hvisor Rust 本体和 x86 boot stub 构建；后续 zone0 Linux、rootfs、ISO、hvisor-tool driver 和 QEMU 运行会切换到 `.#driver` shell。

```bash
nix develop .#hvisor
```

确认 shell 已设置以下路径。这里先检查环境是否正常；真正生成 ISO 和启动 QEMU 时会在后面的 `.#driver` shell 中再次使用这些路径。

```bash
printf 'VDSO_LIBRARY_DIR=%s\n' "$VDSO_LIBRARY_DIR"
printf 'OVMF_FD=%s\n' "$OVMF_FD"
printf 'GRUB_X86_64_EFI=%s\n' "$GRUB_X86_64_EFI"
ls -ld "$OVMF_FD" "$GRUB_X86_64_EFI"
```

### 3. 编译 hvisor

hvisor x86_64 QEMU 使用 `ARCH=x86_64 BOARD=qemu`。下面先生成 Cargo 配置，再构建 hvisor ELF 和 x86 boot stub。拆分执行便于后续手动准备 zone0 镜像和 ISO。

```bash
cd ref/hvisor
make ARCH=x86_64 BOARD=qemu MODE=release defconfig
make ARCH=x86_64 BOARD=qemu MODE=release clean_check gen_cargo_config
make ARCH=x86_64 BOARD=qemu MODE=release elf
make ARCH=x86_64 BOARD=qemu MODE=release boot
ls -lh target/x86_64-unknown-none/release/hvisor \
  platform/x86_64/qemu/image/bootloader/out/boot.bin
cd ../..
```

### 4. 切换到 driver 环境

退出 hvisor shell，进入 driver shell。Linux v5.19、zone0 rootfs、hvisor ISO 和 hvisor-tool driver 都在这个 shell 中准备。

```bash
exit
nix develop .#driver
```

确认 driver shell 已设置 ISO/QEMU 所需路径。

```bash
printf 'OVMF_FD=%s\n' "$OVMF_FD"
printf 'GRUB_X86_64_EFI=%s\n' "$GRUB_X86_64_EFI"
ls -ld "$OVMF_FD" "$GRUB_X86_64_EFI"
```

### 5. 编译 zone0 Linux 并构建 rootfs

编译 Linux v5.19，并用 Ubuntu 22.04 base 构建 `rootfs1.img`。本文档后续还会把 hvisor-tool、Asterinas 内核和验证材料放入同一个 rootfs，因此这里把 rootfs 大小设为 5G。

```bash
linux_dir="$PWD/.cache/linux-v5.19-hvisor"
rootfs_img="$PWD/.cache/rootfs1.img"
rootfs_mount="$PWD/.cache/rootfs"
ubuntu_base="$PWD/.cache/ubuntu-base-22.04.5-base-amd64.tar.gz"
image_dir="$PWD/ref/hvisor/platform/x86_64/qemu/image"
kernel_dir="$image_dir/kernel"
virtdisk_dir="$image_dir/virtdisk"

mkdir -p .cache "$kernel_dir" "$virtdisk_dir"
git clone --depth 1 --branch v5.19 \
  https://github.com/torvalds/linux.git "$linux_dir"

cd "$linux_dir"
git checkout v5.19
make ARCH=x86_64 defconfig
./scripts/config --enable CONFIG_X86_X2APIC
./scripts/config --enable CONFIG_ACRN_GUEST
./scripts/config --enable CONFIG_BLK_DEV_RAM
./scripts/config --enable CONFIG_IPV6
./scripts/config --enable CONFIG_BRIDGE
./scripts/config --enable CONFIG_TUN
./scripts/config --enable CONFIG_VIRTIO
./scripts/config --enable CONFIG_VIRTIO_PCI
./scripts/config --enable CONFIG_VIRTIO_BLK
./scripts/config --enable CONFIG_VIRTIO_MMIO
./scripts/config --enable CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES
./scripts/config --enable CONFIG_EXT4_FS
./scripts/config --enable CONFIG_DEVTMPFS
./scripts/config --enable CONFIG_DEVTMPFS_MOUNT
./scripts/config --disable CONFIG_WERROR
./scripts/config --set-str CONFIG_LOCALVERSION ""
./scripts/config --disable CONFIG_LOCALVERSION_AUTO
make ARCH=x86_64 LOCALVERSION= olddefconfig
make ARCH=x86_64 LOCALVERSION= -j"$(nproc)"
cd -

curl -L --fail -C - \
  -o "$ubuntu_base" \
  http://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04.5-base-amd64.tar.gz

rm -f "$rootfs_img"
dd if=/dev/zero of="$rootfs_img" bs=1M count=5120 status=progress
mkfs.ext4 -F "$rootfs_img"

rm -rf "$rootfs_mount"
mkdir -p "$rootfs_mount"
sudo mount -t ext4 "$rootfs_img" "$rootfs_mount"
sudo tar -xzf "$ubuntu_base" -C "$rootfs_mount"
sudo cp /etc/resolv.conf "$rootfs_mount/etc/resolv.conf"
sudo mount -t proc /proc "$rootfs_mount/proc"
sudo mount -t sysfs /sys "$rootfs_mount/sys"
sudo mount -o bind /dev "$rootfs_mount/dev"
sudo mount -o bind /dev/pts "$rootfs_mount/dev/pts"

sudo chroot "$rootfs_mount" \
  env DEBIAN_FRONTEND=noninteractive \
  apt-get update
sudo chroot "$rootfs_mount" \
  env DEBIAN_FRONTEND=noninteractive \
  apt-get install -y --no-install-recommends \
    git sudo vim bash-completion \
    kmod net-tools iputils-ping resolvconf ntpdate screen ncurses-base \
    pciutils iproute2 isc-dhcp-client systemd bridge-utils \
    util-linux procps ca-certificates

sudo tee "$rootfs_mount/init" >/dev/null <<'EOF'
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
mkdir -p /dev/pts
mount -t devpts none /dev/pts
echo
echo "Hello Zone 0!"
echo "This boot took $(cut -d' ' -f1 /proc/uptime) seconds"
echo
script /dev/null -c "hostname zone0 && su"
EOF
sudo chmod 0755 "$rootfs_mount/init"

sudo umount "$rootfs_mount/dev/pts"
sudo umount "$rootfs_mount/dev"
sudo umount "$rootfs_mount/sys"
sudo umount "$rootfs_mount/proc"
sudo umount "$rootfs_mount"

cp "$linux_dir/arch/x86/boot/setup.bin" "$kernel_dir/setup.bin"
cp "$linux_dir/arch/x86/boot/vmlinux.bin" "$kernel_dir/vmlinux.bin"
cp --sparse=always "$rootfs_img" "$virtdisk_dir/rootfs1.img"
printf 'linux_dir=%q\nrootfs_img=%q\n' \
  "$linux_dir" "$virtdisk_dir/rootfs1.img" \
  > .cache/hvisor-zone0.env
ls -lh "$kernel_dir/setup.bin" "$kernel_dir/vmlinux.bin" "$virtdisk_dir/rootfs1.img"
```

### 6. 构建 hvisor ISO

生成 ISO 前，把 hvisor ELF、`boot.bin`、`setup.bin` 和 `vmlinux.bin` 放到 hvisor x86_64 QEMU 平台约定的 ISO 输入目录；GRUB 配置文件直接使用 hvisor 仓库内已有模板。

```bash
source .cache/hvisor-zone0.env
cd ref/hvisor
image_dir="$PWD/platform/x86_64/qemu/image"
iso_dir="$image_dir/iso"
kernel_dir="$iso_dir/boot/kernel"
output_iso="$image_dir/virtdisk/hvisor.iso"

mkdir -p "$kernel_dir" "$(dirname "$output_iso")"
cp target/x86_64-unknown-none/release/hvisor "$iso_dir/boot/hvisor"
cp "$image_dir/bootloader/out/boot.bin" "$kernel_dir/boot.bin"
cp "$image_dir/kernel/setup.bin" "$kernel_dir/setup.bin"
cp "$image_dir/kernel/vmlinux.bin" "$kernel_dir/vmlinux.bin"
grub-mkrescue -d "$GRUB_X86_64_EFI" -o "$output_iso" "$iso_dir"
ls -lh "$output_iso"
cd ../..
```

### 7. 切换到 Asterinas 开发环境

进入 Asterinas 开发环境。该 shell 使用 Asterinas 所需的 Rust nightly。

```bash
nix develop .#asterinas
rustc --version
```

### 8. 准备 Asterinas vDSO

Asterinas 构建需要 vDSO 库路径。下面下载 `asterinas/linux_vdso`，并设置 `VDSO_LIBRARY_DIR`。

```bash
git clone https://github.com/asterinas/linux_vdso.git .cache/linux_vdso
git -C .cache/linux_vdso fetch origin
git -C .cache/linux_vdso checkout 7489835
export VDSO_LIBRARY_DIR="$PWD/.cache/linux_vdso"
ls -lh "$VDSO_LIBRARY_DIR/vdso_x86_64.so"
```

### 9. 编译 Asterinas

下面按 hvisor x86_64 legacy boot 路线编译 Asterinas bzImage，并使用与默认 zone 配置一致的 warn 日志级别。

```bash
cd ref/asterinas
export CARGO_HOME="$PWD/../../.cache/cargo-asterinas"
export PATH="$CARGO_HOME/bin:$PATH"
export VDSO_LIBRARY_DIR="$PWD/../../.cache/linux_vdso"
rm -rf target/osdk
make install_osdk
make kernel \
  BOOT_METHOD=qemu-direct \
  BOOT_PROTOCOL=linux-legacy32 \
  LOG_LEVEL=warn \
  BENCHMARK=none \
  ENABLE_KVM=1 \
  OVMF=off
ls -lh target/osdk/aster-kernel-osdk-bin \
  test/initramfs/build/initramfs.cpio.gz \
  test/initramfs/build/ext2.img \
  test/initramfs/build/exfat.img
make -C test/initramfs \
  ENABLE_REGRESSION_TEST=true \
  REGRESSION_TEST_PLATFORM=asterinas
ls -lh test/initramfs/build/initramfs.cpio.gz
initramfs_list=$(mktemp)
gzip -dc test/initramfs/build/initramfs.cpio.gz |
  cpio -t > "$initramfs_list" 2>/dev/null
grep '^test/hello_world$' "$initramfs_list"
grep 'hello_world.*/run_test.sh$' "$initramfs_list"
rm -f "$initramfs_list"
cd ../..
```

### 10. 拆分 Asterinas 内核镜像并准备临时运行目录

hvisor zone 配置分别引用 setup 区和 payload。下面从 Asterinas bzImage 中拆出这两个文件，并把 initramfs、ext2 后端、exfat 后端和配置文件放入临时运行目录。

```bash
mkdir -p .cache
work_dir=$(mktemp -d -p "$PWD/.cache" hvisor-asterinas-submit.XXXXXX)
output_dir="$work_dir/asterinas-hvisor-x86_64"
bzimage="$PWD/ref/asterinas/target/osdk/aster-kernel-osdk-bin"
boot_bin="$PWD/ref/hvisor/platform/x86_64/qemu/image/bootloader/out/boot.bin"
initramfs_img="$PWD/ref/asterinas/test/initramfs/build/initramfs.cpio.gz"
ext2_img="$PWD/ref/asterinas/test/initramfs/build/ext2.img"
exfat_img="$PWD/ref/asterinas/test/initramfs/build/exfat.img"

mkdir -p "$output_dir"
setup_sects=$(od -An -j 497 -N 1 -tu1 "$bzimage" | tr -d ' ')
if [ "$setup_sects" = "0" ]; then
  setup_size=$((4 * 512))
else
  setup_size=$(((setup_sects + 1) * 512))
fi

head -c "$setup_size" "$bzimage" > "$output_dir/aster-setup.bin"
tail -c +"$((setup_size + 1))" "$bzimage" > "$output_dir/aster-vmlinux.bin"
cp "$boot_bin" "$output_dir/boot.bin"
cp -L "$initramfs_img" "$output_dir/aster-initramfs.cpio.gz"
cp "$ext2_img" "$output_dir/asterinas-ext2.img"
cp "$exfat_img" "$output_dir/asterinas-exfat.img"
cp zone1_asterinas.json "$output_dir/zone1_asterinas.json"
cp zone1_asterinas_boot_hello.json "$output_dir/zone1_asterinas_boot_hello.json"
cp virtio_cfg_asterinas.json "$output_dir/virtio_cfg_asterinas.json"
printf 'output_dir=%q\n' "$output_dir" > .cache/hvisor-asterinas-materials.env
ls -lh "$output_dir"
```

### 11. 构建 hvisor-tool

hvisor-tool 在 zone0 中提供 `/hvisor` 命令和 `hvisor.ko` 模块。下面构建静态 `/hvisor`，并使用 Linux v5.19 构建树编译 `hvisor.ko`。

如果当前仍在 Asterinas 开发 shell，先退出，回到 driver shell。后面的 Linux `modules_prepare`、hvisor-tool 构建、rootfs 部署和 QEMU 运行都在这个 shell 中执行。

```bash
exit
nix develop .#driver
```

确认 driver shell 中的输出目录和编译器：

```bash
source .cache/hvisor-asterinas-materials.env
source .cache/hvisor-zone0.env
gcc --version | head -n 1
printf 'LD_LIBRARY_PATH=%s\n' "${LD_LIBRARY_PATH-}"
```

```bash
make -C "$linux_dir" ARCH=x86_64 LOCALVERSION= olddefconfig
make -C "$linux_dir" ARCH=x86_64 LOCALVERSION= modules_prepare

hvisor_tool_dir="$PWD/.cache/hvisor-tool-main"
git clone https://github.com/syswonder/hvisor-tool.git "$hvisor_tool_dir"
git -C "$hvisor_tool_dir" checkout e4f6931dc9d26e9f748eacd37f3b982fd66778b0
make -C "$hvisor_tool_dir" \
  tools \
  ARCH=x86_64 \
  LOG=LOG_INFO \
  LIBC=musl \
  CROSS_COMPILE=x86_64-unknown-linux-musl- \
  CFLAGS="-Wall -Wextra -Wno-error=incompatible-pointer-types -DHLOG=LOG_INFO -pthread -O2"
make -C "$hvisor_tool_dir" \
  driver \
  ARCH=x86_64 \
  LOG=LOG_INFO \
  KDIR="$linux_dir" \
  LIBC=musl \
  CROSS_COMPILE= \
  LOCALVERSION=

modinfo "$hvisor_tool_dir/output/hvisor.ko" | grep 'vermagic: *5[.]19[.]0 SMP'
ls -lh "$hvisor_tool_dir/output/hvisor" "$hvisor_tool_dir/output/hvisor.ko"
```

### 12. 准备系统功能验证材料

下面在启动 QEMU 之前准备系统功能验证材料，并写入 Asterinas 使用的 ext2 后端盘。这样后续进入 Asterinas shell 后可以直接运行验证命令，不需要退出 QEMU 再修改镜像。

该步骤需要拉取或使用 `docker.io/alicesama/os-contest-image:v0.2`，建议当前文件系统至少保留 30G 可用空间。

```bash
capability_tests_commit=9ac474b8c6af8be405e83dea1c04756073bc20cf
capability_tests_src="$PWD/.cache/testsuits-for-oskernel"
if [ ! -d "$capability_tests_src/.git" ]; then
  git clone https://github.com/oscomp/testsuits-for-oskernel.git "$capability_tests_src"
fi
git -C "$capability_tests_src" fetch origin
git -C "$capability_tests_src" checkout --detach "$capability_tests_commit"

capability_tests_work=$(mktemp -d -p "$PWD/.cache" testsuits-x86_64.XXXXXX)
cp -a "$capability_tests_src"/. "$capability_tests_work"/

podman run --rm \
  -v "$capability_tests_work:/code" \
  -w /code \
  docker.io/alicesama/os-contest-image:v0.2 \
  bash -lc '
    set -euo pipefail
    mkdir -p out/x86_64/glibc
    make -f Makefile.sub \
      ARCH=x86_64 \
      PREFIX=x86_64-linux-gnu- \
      DESTDIR=/code/out/x86_64/glibc \
      busybox lua iozone unixbench libc-test
    mkdir -p /code/out/x86_64/glibc/lib /code/out/x86_64/glibc/lib64
    cp /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /code/out/x86_64/glibc/lib/
    cp /lib/x86_64-linux-gnu/libc.so.6 /code/out/x86_64/glibc/lib/
    cp /lib/x86_64-linux-gnu/libm.so.6 /code/out/x86_64/glibc/lib/
    cp /code/out/x86_64/glibc/lib/* /code/out/x86_64/glibc/lib64/
  ' || exit 1

capability_dir="$capability_tests_work/out/x86_64/glibc"
cp "$capability_tests_work/scripts/unixbench/sort.src" "$capability_dir/sort.src"
find "$capability_dir" -type f -name '*.sh' -exec chmod 0755 {} +

find "$capability_dir" -type f -print0 | while IFS= read -r -d '' file; do
  case "$file" in
    "$capability_dir"/lib/*|"$capability_dir"/lib64/*) continue ;;
  esac
  if file "$file" | grep -q 'ELF .* dynamically linked'; then
    if readelf -l "$file" 2>/dev/null | grep -q 'INTERP'; then
      patchelf \
        --set-interpreter /ext2/capability/lib/ld-linux-x86-64.so.2 \
        --set-rpath /ext2/capability/lib:/ext2/capability/lib64 \
        "$file"
    else
      patchelf \
        --set-rpath /ext2/capability/lib:/ext2/capability/lib64 \
        "$file" 2>/dev/null || true
    fi
  fi
done

source .cache/hvisor-asterinas-materials.env
ext2_backend="$output_dir/asterinas-ext2.img"
e2rm -vr "$ext2_backend:/capability" 2>/dev/null || true
e2mkdir -G 0 -O 0 -P 0755 "$ext2_backend:/capability"

(
  cd "$capability_dir"
  find . -type d -print | while IFS= read -r dir; do
    [ "$dir" = "." ] && continue
    e2mkdir -G 0 -O 0 -P 0755 \
      "$ext2_backend:/capability/${dir#./}"
  done

  find . -type f -print | while IFS= read -r file; do
    mode=0644
    if [ -x "$file" ] || [ "${file%.sh}" != "$file" ]; then
      mode=0755
    fi
    e2cp -G 0 -O 0 -P "$mode" \
      "$file" "$ext2_backend:/capability/${file#./}"
  done
)

e2ls "$ext2_backend:/capability"
```

### 13. 部署文件到 zone0 rootfs

下面把 hvisor-tool、Asterinas 内核、initramfs、virtio 后端镜像和配置文件放入 zone0 rootfs。

`rootfs1.img` 已在前面构建为 5G，足够容纳 Asterinas initramfs、ext2 后端、exfat 后端和系统功能验证材料。`/hvisor` 与 `/hvisor.ko` 来自同一次 hvisor-tool 构建。

```bash
source .cache/hvisor-asterinas-materials.env
rootfs_img="$PWD/ref/hvisor/platform/x86_64/qemu/image/virtdisk/rootfs1.img"
source_dir="$output_dir"

for path in \
  hvisor \
  hvisor.ko \
  boot.bin \
  aster-setup.bin \
  aster-vmlinux.bin \
  aster-initramfs.cpio.gz \
  asterinas-ext2.img \
  asterinas-exfat.img \
  zone1_asterinas.json \
  zone1_asterinas_boot_hello.json \
  virtio_cfg_asterinas.json
do
  e2rm "$rootfs_img:/$path" 2>/dev/null || true
done

e2cp -G 0 -O 0 -P 0755 "$hvisor_tool_dir/output/hvisor" "$rootfs_img:/hvisor"
e2cp -G 0 -O 0 -P 0644 "$hvisor_tool_dir/output/hvisor.ko" "$rootfs_img:/hvisor.ko"
e2cp -G 0 -O 0 -P 0644 "$source_dir/boot.bin" "$rootfs_img:/boot.bin"
e2cp -G 0 -O 0 -P 0644 "$source_dir/aster-setup.bin" "$rootfs_img:/aster-setup.bin"
e2cp -G 0 -O 0 -P 0644 "$source_dir/aster-vmlinux.bin" "$rootfs_img:/aster-vmlinux.bin"
e2cp -G 0 -O 0 -P 0644 "$source_dir/aster-initramfs.cpio.gz" "$rootfs_img:/aster-initramfs.cpio.gz"
e2cp -G 0 -O 0 -P 0644 "$source_dir/asterinas-ext2.img" "$rootfs_img:/asterinas-ext2.img"
e2cp -G 0 -O 0 -P 0644 "$source_dir/asterinas-exfat.img" "$rootfs_img:/asterinas-exfat.img"
e2cp -G 0 -O 0 -P 0644 "$source_dir/zone1_asterinas.json" "$rootfs_img:/zone1_asterinas.json"
e2cp -G 0 -O 0 -P 0644 "$source_dir/zone1_asterinas_boot_hello.json" "$rootfs_img:/zone1_asterinas_boot_hello.json"
e2cp -G 0 -O 0 -P 0644 "$source_dir/virtio_cfg_asterinas.json" "$rootfs_img:/virtio_cfg_asterinas.json"

e2ls "$rootfs_img:/" | grep -E 'hvisor|aster-|zone1_asterinas|virtio_cfg_asterinas'
```

### 14. 启动 hvisor 和 zone0 Linux

下面使用 Nix shell 提供的 `OVMF_FD` 启动 QEMU。

```bash
cd ref/hvisor
sudo qemu-system-x86_64 \
  -machine q35,kernel-irqchip=split \
  -cpu host,+x2apic,+invtsc,+vmx \
  -accel kvm \
  -smp 4 \
  -serial mon:stdio \
  -m 4G \
  -bios "$OVMF_FD" \
  -vga std \
  -nodefaults \
  -net nic \
  -net user \
  -device intel-iommu,intremap=on,eim=on,caching-mode=on,device-iotlb=on,aw-bits=48 \
  -device ioh3420,id=pcie.1,chassis=1 \
  -drive if=none,file=platform/x86_64/qemu/image/virtdisk/rootfs1.img,id=X10008000,format=raw \
  -device virtio-blk-pci,bus=pcie.1,drive=X10008000,disable-legacy=on,disable-modern=off,iommu_platform=on,ats=on \
  -drive file=platform/x86_64/qemu/image/virtdisk/hvisor.iso,format=raw,index=0,media=disk \
  -boot d
```

zone0 启动成功后，串口中应出现：

```text
root@zone0:/#
```

### 15. 在 zone0 中启动 Asterinas 交互 shell

hvisor-tool 官方使用方式是在 zone0 中先加载 `hvisor.ko`，再启动 virtio daemon，最后执行 `zone start`。下面命令在 QEMU 的 zone0 shell 中执行。

先加载 hvisor 内核模块，并启动 virtio daemon：

```bash
insmod /hvisor.ko
ls /dev/pts
nohup /hvisor virtio start ./virtio_cfg_asterinas.json &
ls /dev/pts
```

启动 Asterinas zone1：

```bash
/hvisor zone start ./zone1_asterinas.json
/hvisor zone list
```

hvisor-tool 会在 `/dev/pts` 下创建 Asterinas console。比较 virtio daemon 启动前后两次 `ls /dev/pts` 的输出，新增编号就是 Asterinas console；如果第二次还没有出现新增编号，再执行一次 `ls /dev/pts`。将下面的 `xxx` 替换为该编号：

```bash
asterinas_console=/dev/pts/xxx
screen "$asterinas_console"
```

进入 Asterinas shell 后可执行：

```bash
cat /proc/cmdline
ls /
mount | grep -E 'ext2|exfat'
grep -E 'processor|model name' /proc/cpuinfo 2>/dev/null || true
grep -E 'MemTotal|MemFree|MemAvailable' /proc/meminfo 2>/dev/null || true
mkdir -p /tmp/hvisor-smoke
printf 'syscall-ok\n' > /tmp/hvisor-smoke/syscall.txt
cat /tmp/hvisor-smoke/syscall.txt
rm -f /tmp/hvisor-smoke/syscall.txt
printf 'hvisor ext2 smoke\n' > /ext2/hvisor-smoke.txt
cat /ext2/hvisor-smoke.txt
rm /ext2/hvisor-smoke.txt
printf 'hvisor exfat smoke\n' > /exfat/hvisor-smoke.txt
cat /exfat/hvisor-smoke.txt
rm /exfat/hvisor-smoke.txt
sync
```

这些 shell 验证命令通过时，预期结果如下：`cat /proc/cmdline` 能看到 `console=hvc0 console=ttyS0`、`loglevel=warn` 和三条 `virtio_mmio.device=`；`mount` 输出包含 `/ext2` 和 `/exfat`；`/tmp/hvisor-smoke/syscall.txt` 能读回 `syscall-ok`；`/ext2/hvisor-smoke.txt` 能读回 `hvisor ext2 smoke`；`/exfat/hvisor-smoke.txt` 能读回 `hvisor exfat smoke`。

默认交互配置的预期输出如下。验收以 `zone list` 显示 `asterinas1 running`、Asterinas 初始化日志和 shell 基本功能检查通过为准。

```text
OSTD initialized. Preparing components.
x2APIC found!
TSC frequency:
timer: Enable APIC TSC deadline mode
irq: IOAPIC found
Booting 1 processors
Processor 1 started.
virtio: Found MMIO device at 0x5950f000, device ID 3
virtio: Found MMIO device at 0x5950f400, device ID 2
virtio: Found MMIO device at 0x5950f800, device ID 2
[kernel] rootfs is ready
No arguments were provided to the init process. Spawn a shell by default.
```

### 16. 可选：执行最小启动检查

Asterinas initramfs 中的 `/init` 在没有参数时进入 `/bin/sh`；最小启动检查则在 cmdline 的 `--` 后传入 `/test/boot_hello.sh`。该检查用于确认 Asterinas 能完成启动并运行用户态脚本；交互验证仍使用上一节的默认配置。

如果还要继续执行第三章系统功能验证，先保持上一节的默认交互 shell，完成第三章后再运行本小节（虽然感觉也没有必要）。下面命令会关闭默认交互 zone，并启动 `zone1_asterinas_boot_hello.json`。若前面已经通过 `screen` 连接 Asterinas console，先按 `Ctrl-a d` 退出 screen，再运行这段命令；它会把 hvisor-tool console 保存到 `/tmp/boot-hello-console.log` 并检查 `Successfully booted.`。

```bash
/hvisor zone shutdown -id 1 2>/tmp/zone-shutdown.err || true
rm -f /tmp/boot-hello-console.log /tmp/zone-start-boot-hello.out
cat "$asterinas_console" > /tmp/boot-hello-console.log &
boot_log_pid=$!

/hvisor zone start ./zone1_asterinas_boot_hello.json \
  > /tmp/zone-start-boot-hello.out 2>&1
boot_rc=$?
echo "boot hello zone start rc=$boot_rc"
cat /tmp/zone-start-boot-hello.out

for _ in $(seq 1 60); do
  grep -q 'Successfully booted.' /tmp/boot-hello-console.log && break
  sleep 1
done
grep 'Successfully booted.' /tmp/boot-hello-console.log
kill "$boot_log_pid" 2>/dev/null || true
```

验收以 hvisor-tool 分配的 `/dev/pts/x` 中出现 `Successfully booted.` 为准。QEMU/root console 可用于观察内核初始化日志。

```text
OSTD initialized. Preparing components.
[kernel] rootfs is ready
Successfully booted.
```

## 二、Ubuntu / 非 Nix flake 环境运行

Ubuntu 路线不依赖 Nix flake 章节，但仍从文首克隆的复现配置仓库根目录开始执行。仓库中的三份 JSON 文件会在后续步骤部署到 zone0 rootfs。

### 1. 安装系统依赖

本路线以 Ubuntu 24.04 为验证环境，不使用根目录 `flake.nix`。Asterinas initramfs 构建会调用上游 Makefile 中的 `nix-build`，因此仍需要安装 Ubuntu 的 `nix-bin` 和 `nix-setup-systemd`。

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  git \
  openssh-client \
  build-essential \
  gcc \
  gcc-multilib \
  clang \
  lld \
  llvm \
  binutils \
  bison \
  flex \
  bc \
  make \
  pkg-config \
  libssl-dev \
  libelf-dev \
  libxml2-utils \
  python3 \
  python3-venv \
  perl \
  file \
  cpio \
  gzip \
  xz-utils \
  unzip \
  zip \
  jq \
  ripgrep \
  nasm \
  mtools \
  dosfstools \
  e2fsprogs \
  e2tools \
  exfatprogs \
  parted \
  grub-efi-amd64-bin \
  grub-pc-bin \
  grub-common \
  xorriso \
  ovmf \
  qemu-system-x86 \
  qemu-utils \
  patchelf \
  podman \
  nix-bin \
  nix-setup-systemd \
  expect \
  screen \
  socat \
  sqlite3 \
  numactl \
  strace \
  kmod
```

### 2. 准备源码工作区

执行以下命令下载两个源码仓库，并切换到本文固定使用的 commit。Rust 工具链声明来自这两个 fork 中各自的 `rust-toolchain.toml`。

```bash
hvisor_remote=${HVISOR_REMOTE:-https://github.com/xingmin1/hvisor.git}
asterinas_remote=${ASTERINAS_REMOTE:-https://github.com/xingmin1/asterinas-in-hvisor.git}
hvisor_commit=add78abf74dfa298090967e0ee75b873e6d8fb26
asterinas_commit=1f325b3da2e97f7e00e18d37ebec8c9249b7eccb

mkdir -p ref
if [ ! -d ref/hvisor/.git ]; then
  git clone "$hvisor_remote" ref/hvisor
fi
if [ ! -d ref/asterinas/.git ]; then
  git clone "$asterinas_remote" ref/asterinas
fi

git -C ref/hvisor fetch "$hvisor_remote" "$hvisor_commit"
git -C ref/hvisor checkout --detach "$hvisor_commit"
git -C ref/asterinas fetch "$asterinas_remote" "$asterinas_commit"
git -C ref/asterinas checkout --detach "$asterinas_commit"

git -C ref/hvisor rev-parse HEAD
git -C ref/asterinas rev-parse HEAD
```



### 3. 安装 Rust 工具链

hvisor 与 Asterinas 使用不同 nightly。版本从两个 fork 中各自的 `rust-toolchain.toml` 读取；最终只安装本路线实际需要的 `x86_64-unknown-none` target。安装 `cargo-binutils` 后会提供 `rust-objcopy`、`rust-strip` 等 hvisor 和 Asterinas 构建所需工具名。

```bash
curl https://sh.rustup.rs -sSf | sh -s -- -y --profile minimal
. "$HOME/.cargo/env"

hvisor_rust=$(grep -E '^channel = ' ref/hvisor/rust-toolchain.toml | cut -d '"' -f 2)
asterinas_rust=$(grep -E '^channel = ' ref/asterinas/rust-toolchain.toml | cut -d '"' -f 2)

rustup toolchain install "$hvisor_rust" \
  --profile minimal \
  --component rust-src \
  --component llvm-tools-preview \
  --component rustfmt \
  --component clippy \
  --target x86_64-unknown-none

rustup toolchain install "$asterinas_rust" \
  --profile minimal \
  --component rust-src \
  --component rustc-dev \
  --component llvm-tools-preview \
  --target x86_64-unknown-none

cargo +stable install cargo-binutils --locked
rustc +"$hvisor_rust" --version
rustc +"$asterinas_rust" --version
```

### 4. 设置 GRUB、OVMF 和 vDSO 路径

Ubuntu 24.04 的 `ovmf` 包提供 `/usr/share/ovmf/OVMF.fd`，该路径与 hvisor x86_64 `platform.mk` 使用的单文件 OVMF 启动方式一致。GRUB 模块位于 `/usr/lib/grub/x86_64-efi`；vDSO 放在 `.cache/linux_vdso`，并通过 `VDSO_LIBRARY_DIR` 提供给 Asterinas 构建流程。

```bash
export OVMF_FD=/usr/share/ovmf/OVMF.fd
export GRUB_X86_64_EFI=/usr/lib/grub/x86_64-efi
ls -ld "$OVMF_FD" "$GRUB_X86_64_EFI"

mkdir -p .cache
if [ ! -d .cache/linux_vdso/.git ]; then
  git clone https://github.com/asterinas/linux_vdso.git .cache/linux_vdso
fi
git -C .cache/linux_vdso fetch origin
git -C .cache/linux_vdso checkout 7489835
export VDSO_LIBRARY_DIR="$PWD/.cache/linux_vdso"
ls -lh "$VDSO_LIBRARY_DIR/vdso_x86_64.so"
```

### 5. 编译 hvisor

这里同样先生成 Cargo 配置，再分别构建 hvisor ELF 和 x86 boot stub。区别是 Ubuntu 路线依赖 rustup 安装的 hvisor 工具链。

```bash
cd ref/hvisor
cargo +"$hvisor_rust" --version >/dev/null
make ARCH=x86_64 BOARD=qemu MODE=release defconfig
make ARCH=x86_64 BOARD=qemu MODE=release clean_check gen_cargo_config
make ARCH=x86_64 BOARD=qemu MODE=release elf
make ARCH=x86_64 BOARD=qemu MODE=release boot
ls -lh target/x86_64-unknown-none/release/hvisor \
  platform/x86_64/qemu/image/bootloader/out/boot.bin
cd ../..
```

### 6. 准备 zone0 Linux 运行资产并生成 hvisor ISO

按 hvisor 官方 QEMU x86_64 文档编译 Linux v5.19，并用 Ubuntu 22.04 base 构建 `rootfs1.img`。本文档后续还会把 hvisor-tool、Asterinas 内核和验证材料放入同一个 rootfs，因此这里把 rootfs 大小设为 5G。完成后按 hvisor x86_64 QEMU 平台目录结构生成 `hvisor.iso`。

```bash
linux_dir="$PWD/.cache/linux-v5.19-hvisor"
rootfs_img="$PWD/.cache/rootfs1.img"
rootfs_mount="$PWD/.cache/rootfs"
ubuntu_base="$PWD/.cache/ubuntu-base-22.04.5-base-amd64.tar.gz"
image_dir="$PWD/ref/hvisor/platform/x86_64/qemu/image"
kernel_dir="$image_dir/kernel"
virtdisk_dir="$image_dir/virtdisk"

mkdir -p .cache "$kernel_dir" "$virtdisk_dir"
if [ ! -d "$linux_dir/.git" ]; then
  git clone --depth 1 --branch v5.19 \
    https://github.com/torvalds/linux.git "$linux_dir"
fi

cd "$linux_dir"
git checkout v5.19
make ARCH=x86_64 defconfig
./scripts/config --enable CONFIG_X86_X2APIC
./scripts/config --enable CONFIG_ACRN_GUEST
./scripts/config --enable CONFIG_BLK_DEV_RAM
./scripts/config --enable CONFIG_IPV6
./scripts/config --enable CONFIG_BRIDGE
./scripts/config --enable CONFIG_TUN
./scripts/config --enable CONFIG_VIRTIO
./scripts/config --enable CONFIG_VIRTIO_PCI
./scripts/config --enable CONFIG_VIRTIO_BLK
./scripts/config --enable CONFIG_VIRTIO_MMIO
./scripts/config --enable CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES
./scripts/config --enable CONFIG_EXT4_FS
./scripts/config --enable CONFIG_DEVTMPFS
./scripts/config --enable CONFIG_DEVTMPFS_MOUNT
./scripts/config --disable CONFIG_WERROR
./scripts/config --set-str CONFIG_LOCALVERSION ""
./scripts/config --disable CONFIG_LOCALVERSION_AUTO
make ARCH=x86_64 LOCALVERSION= olddefconfig
make ARCH=x86_64 LOCALVERSION= -j"$(nproc)"
cd -

curl -L --fail -C - \
  -o "$ubuntu_base" \
  http://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04.5-base-amd64.tar.gz

rm -f "$rootfs_img"
dd if=/dev/zero of="$rootfs_img" bs=1M count=5120 status=progress
mkfs.ext4 -F "$rootfs_img"

rm -rf "$rootfs_mount"
mkdir -p "$rootfs_mount"
sudo mount -t ext4 "$rootfs_img" "$rootfs_mount"
sudo tar -xzf "$ubuntu_base" -C "$rootfs_mount"
sudo cp /etc/resolv.conf "$rootfs_mount/etc/resolv.conf"
sudo mount -t proc /proc "$rootfs_mount/proc"
sudo mount -t sysfs /sys "$rootfs_mount/sys"
sudo mount -o bind /dev "$rootfs_mount/dev"
sudo mount -o bind /dev/pts "$rootfs_mount/dev/pts"

sudo chroot "$rootfs_mount" \
  env DEBIAN_FRONTEND=noninteractive \
  apt-get update
sudo chroot "$rootfs_mount" \
  env DEBIAN_FRONTEND=noninteractive \
  apt-get install -y --no-install-recommends \
    git sudo vim bash-completion \
    kmod net-tools iputils-ping resolvconf ntpdate screen ncurses-base \
    pciutils iproute2 isc-dhcp-client systemd bridge-utils \
    util-linux procps ca-certificates

sudo tee "$rootfs_mount/init" >/dev/null <<'EOF'
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
mkdir -p /dev/pts
mount -t devpts none /dev/pts
echo
echo "Hello Zone 0!"
echo "This boot took $(cut -d' ' -f1 /proc/uptime) seconds"
echo
script /dev/null -c "hostname zone0 && su"
EOF
sudo chmod 0755 "$rootfs_mount/init"

sudo umount "$rootfs_mount/dev/pts"
sudo umount "$rootfs_mount/dev"
sudo umount "$rootfs_mount/sys"
sudo umount "$rootfs_mount/proc"
sudo umount "$rootfs_mount"

cp "$linux_dir/arch/x86/boot/setup.bin" "$kernel_dir/setup.bin"
cp "$linux_dir/arch/x86/boot/vmlinux.bin" "$kernel_dir/vmlinux.bin"
cp --sparse=always "$rootfs_img" "$virtdisk_dir/rootfs1.img"
printf 'linux_dir=%q\nrootfs_img=%q\n' \
  "$linux_dir" "$virtdisk_dir/rootfs1.img" \
  > .cache/hvisor-zone0.env
ls -lh "$kernel_dir/setup.bin" "$kernel_dir/vmlinux.bin" "$virtdisk_dir/rootfs1.img"

cd ref/hvisor
image_dir="$PWD/platform/x86_64/qemu/image"
iso_dir="$image_dir/iso"
kernel_dir="$iso_dir/boot/kernel"
output_iso="$image_dir/virtdisk/hvisor.iso"

mkdir -p "$kernel_dir" "$(dirname "$output_iso")"
cp target/x86_64-unknown-none/release/hvisor "$iso_dir/boot/hvisor"
cp "$image_dir/bootloader/out/boot.bin" "$kernel_dir/boot.bin"
cp "$image_dir/kernel/setup.bin" "$kernel_dir/setup.bin"
cp "$image_dir/kernel/vmlinux.bin" "$kernel_dir/vmlinux.bin"
grub-mkrescue -d "$GRUB_X86_64_EFI" -o "$output_iso" "$iso_dir"
ls -lh "$output_iso"
cd ../..
```

### 7. 编译 Asterinas

下面先安装 Asterinas OSDK，再编译内核和 initramfs。这里使用 rustup 安装的 Asterinas 工具链；`LOG_LEVEL=warn` 与默认 zone 配置保持一致。

```bash
cd ref/asterinas
export CARGO_HOME="$PWD/../../.cache/cargo-asterinas"
export PATH="$CARGO_HOME/bin:$PATH"
export VDSO_LIBRARY_DIR="$PWD/../../.cache/linux_vdso"
rm -rf target/osdk
cargo +"$asterinas_rust" --version >/dev/null
make install_osdk
make kernel \
  BOOT_METHOD=qemu-direct \
  BOOT_PROTOCOL=linux-legacy32 \
  LOG_LEVEL=warn \
  BENCHMARK=none \
  ENABLE_KVM=1 \
  OVMF=off
ls -lh target/osdk/aster-kernel-osdk-bin \
  test/initramfs/build/initramfs.cpio.gz \
  test/initramfs/build/ext2.img \
  test/initramfs/build/exfat.img
make -C test/initramfs \
  ENABLE_REGRESSION_TEST=true \
  REGRESSION_TEST_PLATFORM=asterinas
ls -lh test/initramfs/build/initramfs.cpio.gz
initramfs_list=$(mktemp)
gzip -dc test/initramfs/build/initramfs.cpio.gz |
  cpio -t > "$initramfs_list" 2>/dev/null
grep '^test/hello_world$' "$initramfs_list"
grep 'hello_world.*/run_test.sh$' "$initramfs_list"
rm -f "$initramfs_list"
cd ../..
```

### 8. 准备 Asterinas 运行材料

这一步按 bzImage header 拆分 setup 和 payload，并复制 Asterinas initramfs 与官方块设备镜像到临时目录。

```bash
mkdir -p .cache
work_dir=$(mktemp -d -p "$PWD/.cache" hvisor-asterinas-submit.XXXXXX)
output_dir="$work_dir/asterinas-hvisor-x86_64"
bzimage="$PWD/ref/asterinas/target/osdk/aster-kernel-osdk-bin"
boot_bin="$PWD/ref/hvisor/platform/x86_64/qemu/image/bootloader/out/boot.bin"
initramfs_img="$PWD/ref/asterinas/test/initramfs/build/initramfs.cpio.gz"
ext2_img="$PWD/ref/asterinas/test/initramfs/build/ext2.img"
exfat_img="$PWD/ref/asterinas/test/initramfs/build/exfat.img"

mkdir -p "$output_dir"
setup_sects=$(od -An -j 497 -N 1 -tu1 "$bzimage" | tr -d ' ')
if [ "$setup_sects" = "0" ]; then
  setup_size=$((4 * 512))
else
  setup_size=$(((setup_sects + 1) * 512))
fi

head -c "$setup_size" "$bzimage" > "$output_dir/aster-setup.bin"
tail -c +"$((setup_size + 1))" "$bzimage" > "$output_dir/aster-vmlinux.bin"
cp "$boot_bin" "$output_dir/boot.bin"
cp -L "$initramfs_img" "$output_dir/aster-initramfs.cpio.gz"
cp "$ext2_img" "$output_dir/asterinas-ext2.img"
cp "$exfat_img" "$output_dir/asterinas-exfat.img"
cp zone1_asterinas.json "$output_dir/zone1_asterinas.json"
cp zone1_asterinas_boot_hello.json "$output_dir/zone1_asterinas_boot_hello.json"
cp virtio_cfg_asterinas.json "$output_dir/virtio_cfg_asterinas.json"
printf 'output_dir=%q\n' "$output_dir" > .cache/hvisor-asterinas-materials.env
ls -lh "$output_dir"
```

### 9. 准备系统功能验证材料

下面在启动 QEMU 之前准备系统功能验证材料，并写入 Asterinas 使用的 ext2 后端盘。这样后续进入 Asterinas shell 后可以直接运行验证命令，不需要退出 QEMU 再修改镜像。

该步骤需要拉取或使用 `docker.io/alicesama/os-contest-image:v0.2`，建议当前文件系统至少保留 30G 可用空间。

```bash
capability_tests_commit=9ac474b8c6af8be405e83dea1c04756073bc20cf
capability_tests_src="$PWD/.cache/testsuits-for-oskernel"
if [ ! -d "$capability_tests_src/.git" ]; then
  git clone https://github.com/oscomp/testsuits-for-oskernel.git "$capability_tests_src"
fi
git -C "$capability_tests_src" fetch origin
git -C "$capability_tests_src" checkout --detach "$capability_tests_commit"

capability_tests_work=$(mktemp -d -p "$PWD/.cache" testsuits-x86_64.XXXXXX)
cp -a "$capability_tests_src"/. "$capability_tests_work"/

podman run --rm \
  -v "$capability_tests_work:/code" \
  -w /code \
  docker.io/alicesama/os-contest-image:v0.2 \
  bash -lc '
    set -euo pipefail
    mkdir -p out/x86_64/glibc
    make -f Makefile.sub \
      ARCH=x86_64 \
      PREFIX=x86_64-linux-gnu- \
      DESTDIR=/code/out/x86_64/glibc \
      busybox lua iozone unixbench libc-test
    mkdir -p /code/out/x86_64/glibc/lib /code/out/x86_64/glibc/lib64
    cp /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /code/out/x86_64/glibc/lib/
    cp /lib/x86_64-linux-gnu/libc.so.6 /code/out/x86_64/glibc/lib/
    cp /lib/x86_64-linux-gnu/libm.so.6 /code/out/x86_64/glibc/lib/
    cp /code/out/x86_64/glibc/lib/* /code/out/x86_64/glibc/lib64/
  ' || exit 1

capability_dir="$capability_tests_work/out/x86_64/glibc"
cp "$capability_tests_work/scripts/unixbench/sort.src" "$capability_dir/sort.src"
find "$capability_dir" -type f -name '*.sh' -exec chmod 0755 {} +

find "$capability_dir" -type f -print0 | while IFS= read -r -d '' file; do
  case "$file" in
    "$capability_dir"/lib/*|"$capability_dir"/lib64/*) continue ;;
  esac
  if file "$file" | grep -q 'ELF .* dynamically linked'; then
    if readelf -l "$file" 2>/dev/null | grep -q 'INTERP'; then
      patchelf \
        --set-interpreter /ext2/capability/lib/ld-linux-x86-64.so.2 \
        --set-rpath /ext2/capability/lib:/ext2/capability/lib64 \
        "$file"
    else
      patchelf \
        --set-rpath /ext2/capability/lib:/ext2/capability/lib64 \
        "$file" 2>/dev/null || true
    fi
  fi
done

source .cache/hvisor-asterinas-materials.env
ext2_backend="$output_dir/asterinas-ext2.img"
e2rm -vr "$ext2_backend:/capability" 2>/dev/null || true
e2mkdir -G 0 -O 0 -P 0755 "$ext2_backend:/capability"

(
  cd "$capability_dir"
  find . -type d -print | while IFS= read -r dir; do
    [ "$dir" = "." ] && continue
    e2mkdir -G 0 -O 0 -P 0755 \
      "$ext2_backend:/capability/${dir#./}"
  done

  find . -type f -print | while IFS= read -r file; do
    mode=0644
    if [ -x "$file" ] || [ "${file%.sh}" != "$file" ]; then
      mode=0755
    fi
    e2cp -G 0 -O 0 -P "$mode" \
      "$file" "$ext2_backend:/capability/${file#./}"
  done
)

e2ls "$ext2_backend:/capability"
```

### 10. 构建 hvisor-tool 并部署到 zone0 rootfs

hvisor-tool 固定到以下 commit，并使用同一次构建得到的 `/hvisor` 与 `/hvisor.ko`。Ubuntu 路线使用 hvisor-tool 默认的 x86_64 GNU 工具链前缀构建用户态工具；生成的 `/hvisor` 仍由 hvisor-tool Makefile 静态链接。

```bash
source .cache/hvisor-zone0.env
make -C "$linux_dir" ARCH=x86_64 LOCALVERSION= olddefconfig
make -C "$linux_dir" ARCH=x86_64 LOCALVERSION= modules_prepare

hvisor_tool_dir="$PWD/.cache/hvisor-tool-main"
if [ ! -d "$hvisor_tool_dir/.git" ]; then
  git clone https://github.com/syswonder/hvisor-tool.git "$hvisor_tool_dir"
else
  git -C "$hvisor_tool_dir" fetch origin
fi
git -C "$hvisor_tool_dir" checkout e4f6931dc9d26e9f748eacd37f3b982fd66778b0
make -C "$hvisor_tool_dir" \
  tools \
  ARCH=x86_64 \
  LOG=LOG_INFO \
  LIBC=gnu
make -C "$hvisor_tool_dir" \
  driver \
  ARCH=x86_64 \
  LOG=LOG_INFO \
  KDIR="$linux_dir" \
  LIBC=gnu \
  CROSS_COMPILE= \
  LOCALVERSION=
modinfo "$hvisor_tool_dir/output/hvisor.ko" | grep 'vermagic: *5[.]19[.]0 SMP'
ls -lh "$hvisor_tool_dir/output/hvisor" "$hvisor_tool_dir/output/hvisor.ko"

source .cache/hvisor-asterinas-materials.env
rootfs_img="$PWD/ref/hvisor/platform/x86_64/qemu/image/virtdisk/rootfs1.img"
source_dir="$output_dir"

for path in \
  hvisor \
  hvisor.ko \
  boot.bin \
  aster-setup.bin \
  aster-vmlinux.bin \
  aster-initramfs.cpio.gz \
  asterinas-ext2.img \
  asterinas-exfat.img \
  zone1_asterinas.json \
  zone1_asterinas_boot_hello.json \
  virtio_cfg_asterinas.json
do
  e2rm "$rootfs_img:/$path" 2>/dev/null || true
done

e2cp -G 0 -O 0 -P 0755 "$hvisor_tool_dir/output/hvisor" "$rootfs_img:/hvisor"
e2cp -G 0 -O 0 -P 0644 "$hvisor_tool_dir/output/hvisor.ko" "$rootfs_img:/hvisor.ko"
e2cp -G 0 -O 0 -P 0644 "$source_dir/boot.bin" "$rootfs_img:/boot.bin"
e2cp -G 0 -O 0 -P 0644 "$source_dir/aster-setup.bin" "$rootfs_img:/aster-setup.bin"
e2cp -G 0 -O 0 -P 0644 "$source_dir/aster-vmlinux.bin" "$rootfs_img:/aster-vmlinux.bin"
e2cp -G 0 -O 0 -P 0644 "$source_dir/aster-initramfs.cpio.gz" "$rootfs_img:/aster-initramfs.cpio.gz"
e2cp -G 0 -O 0 -P 0644 "$source_dir/asterinas-ext2.img" "$rootfs_img:/asterinas-ext2.img"
e2cp -G 0 -O 0 -P 0644 "$source_dir/asterinas-exfat.img" "$rootfs_img:/asterinas-exfat.img"
e2cp -G 0 -O 0 -P 0644 "$source_dir/zone1_asterinas.json" "$rootfs_img:/zone1_asterinas.json"
e2cp -G 0 -O 0 -P 0644 "$source_dir/zone1_asterinas_boot_hello.json" "$rootfs_img:/zone1_asterinas_boot_hello.json"
e2cp -G 0 -O 0 -P 0644 "$source_dir/virtio_cfg_asterinas.json" "$rootfs_img:/virtio_cfg_asterinas.json"

e2ls "$rootfs_img:/" | grep -E 'hvisor|aster-|zone1_asterinas|virtio_cfg_asterinas'
```

### 11. 启动 hvisor、进入 Asterinas shell 并执行 boot_hello

下面启动 hvisor 和 zone0 Linux。Ubuntu 路线使用前文设置的 `OVMF_FD`，QEMU 命令与 Nix 路线相同。

```bash
cd ref/hvisor
qemu-system-x86_64 \
  -machine q35,kernel-irqchip=split \
  -cpu host,+x2apic,+invtsc,+vmx \
  -accel kvm \
  -smp 4 \
  -serial mon:stdio \
  -m 4G \
  -bios "$OVMF_FD" \
  -vga std \
  -nodefaults \
  -net nic \
  -net user \
  -device intel-iommu,intremap=on,eim=on,caching-mode=on,device-iotlb=on,aw-bits=48 \
  -device ioh3420,id=pcie.1,chassis=1 \
  -drive if=none,file=platform/x86_64/qemu/image/virtdisk/rootfs1.img,id=X10008000,format=raw \
  -device virtio-blk-pci,bus=pcie.1,drive=X10008000,disable-legacy=on,disable-modern=off,iommu_platform=on,ats=on \
  -drive file=platform/x86_64/qemu/image/virtdisk/hvisor.iso,format=raw,index=0,media=disk \
  -boot d
```

进入 zone0 shell 后加载 hvisor 内核模块，启动 virtio daemon 和 Asterinas zone：

```bash
insmod /hvisor.ko
ls /dev/pts
nohup /hvisor virtio start ./virtio_cfg_asterinas.json &
ls /dev/pts
/hvisor zone start ./zone1_asterinas.json
/hvisor zone list
```

hvisor-tool 会在 `/dev/pts` 下创建 Asterinas console。比较 virtio daemon 启动前后两次 `ls /dev/pts` 的输出，新增编号就是 Asterinas console；如果第二次还没有出现新增编号，再执行一次 `ls /dev/pts`。将下面的 `xxx` 替换为该编号：

```bash
asterinas_console=/dev/pts/xxx
screen "$asterinas_console"
```

进入 Asterinas shell 后执行最小系统功能验证：

```bash
cat /proc/cmdline
ls /
mount | grep -E 'ext2|exfat'
grep -E 'processor|model name' /proc/cpuinfo 2>/dev/null || true
grep -E 'MemTotal|MemFree|MemAvailable' /proc/meminfo 2>/dev/null || true
mkdir -p /tmp/hvisor-smoke
printf 'syscall-ok\n' > /tmp/hvisor-smoke/syscall.txt
cat /tmp/hvisor-smoke/syscall.txt
rm -f /tmp/hvisor-smoke/syscall.txt
printf 'hvisor ext2 smoke\n' > /ext2/hvisor-smoke.txt
cat /ext2/hvisor-smoke.txt
rm /ext2/hvisor-smoke.txt
printf 'hvisor exfat smoke\n' > /exfat/hvisor-smoke.txt
cat /exfat/hvisor-smoke.txt
rm /exfat/hvisor-smoke.txt
sync
```

这些 shell 验证命令通过时，预期结果如下：`cat /proc/cmdline` 能看到 `console=hvc0 console=ttyS0`、`loglevel=warn` 和三条 `virtio_mmio.device=`；`mount` 输出包含 `/ext2` 和 `/exfat`；`/tmp/hvisor-smoke/syscall.txt` 能读回 `syscall-ok`；`/ext2/hvisor-smoke.txt` 能读回 `hvisor ext2 smoke`；`/exfat/hvisor-smoke.txt` 能读回 `hvisor exfat smoke`。

需要一次性启动验收时，回到 zone0 shell 后启动 `zone1_asterinas_boot_hello.json`。如果还要继续执行第三章系统功能验证，先保持默认交互 shell，完成第三章后再运行下面命令。若前面已经通过 `screen` 连接 Asterinas console，先按 `Ctrl-a d` 退出 screen；下面命令会捕获 hvisor-tool console 并检查 `Successfully booted.`：

```bash
/hvisor zone shutdown -id 1 2>/tmp/zone-shutdown.err || true
rm -f /tmp/boot-hello-console.log /tmp/zone-start-boot-hello.out
cat "$asterinas_console" > /tmp/boot-hello-console.log &
boot_log_pid=$!

/hvisor zone start ./zone1_asterinas_boot_hello.json \
  > /tmp/zone-start-boot-hello.out 2>&1
boot_rc=$?
echo "boot hello zone start rc=$boot_rc"
cat /tmp/zone-start-boot-hello.out

for _ in $(seq 1 60); do
  grep -q 'Successfully booted.' /tmp/boot-hello-console.log && break
  sleep 1
done
grep 'Successfully booted.' /tmp/boot-hello-console.log
kill "$boot_log_pid" 2>/dev/null || true
```

验收以 hvisor-tool 分配的 `/dev/pts/x` 中出现 `Successfully booted.` 为准。QEMU/root console 可用于观察内核初始化日志。

## 三、系统功能验证

本节在 Asterinas shell 中执行。Nix flake 路线和 Ubuntu / 非 Nix flake 路线都已经在启动 QEMU 前把系统能力验证材料写入 `/ext2/capability`，并把带 Asterinas regression 测试目录的 initramfs 部署为 `/aster-initramfs.cpio.gz`。因此这里不需要退出 QEMU，也不需要重新修改 rootfs。

### 用户态程序与系统调用入口验证

下面运行五组用户态系统能力验证

```bash
cd /ext2/capability
ln -sf busybox sh
export PATH=/ext2/capability:/bin:/usr/bin:/sbin:/usr/sbin
chmod +x ./*_testcode.sh

./busybox_testcode.sh
./lua_testcode.sh
./iozone_testcode.sh
./unixbench_testcode.sh
./libctest_testcode.sh
```

这些测试覆盖常用用户态命令、Lua 脚本、文件 IO 吞吐、进程/管道/exec 类 UnixBench 路径和 libc 入口

### 用户态启动、内存、IPC、时间与 IO 能力验证

本小节运行 Asterinas initramfs 中覆盖用户态启动、内存、IPC、时间和 IO 的验证入口。

```bash
cd /test/hello_world && ./run_test.sh
cd /test/memory && ./run_test.sh
cd /test/ipc && ./run_test.sh
cd /test/time && ./run_test.sh
cd /test/io && ./run_test.sh
```

用于测试用户态启动、内存、IPC、时间和 IO 能力
