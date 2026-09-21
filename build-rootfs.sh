#!/usr/bin/env bash
# =============================================================================
#  build-rootfs.sh —— xaga (Redmi Note 11T Pro / MT6895) 可刷入 userdata 的
#                    ext4 rootfs 镜像构建脚本
#
#  支持发行版：arch（作者同款，推荐） / debian / ubuntu
#
#  ---------------------------------------------------------------------------
#  ★ 不可违背的约束（全部来自 MT6895-Mainline/initramfs 的 init.c，硬编码）
#
#   * BOOT_PARTITION 默认 /dev/sdc86（= userdata），文件系统**必须是 ext4**
#     实测日志：`EXT4-fs (sdc86): mounted filesystem ...` → `CINIT: switch_root -> /sbin/init`
#     （注意：旧笔记里的 /dev/mmcblk0p86 在这台机器这块内核上是错的）
#   * NVDATA_PARTITION /dev/sdc13（nvdata），只读 ext4，initramfs 用它取 WiFi/BT NVRAM
#   * pivot 之后执行 **/sbin/init**（systemd），缺了直接黑屏死循环
#   * initramfs 自己会挂 proc/sys/dev/run/tmp/devpts，rootfs 里不需要 /dev 节点
#   * 不读 cmdline，所以 root= / init= 都不用管
#   * rootfs 必须自带 mediatek 固件，否则 WiFi / 蓝牙 / 声卡 / 触控全废
#
#  ---------------------------------------------------------------------------
#  本脚本相对“朴素 bootstrap”额外修掉的问题（都是启动日志里实测出来的）
#   1) shadow.service 开机必失败
#      `'alarm' is a member of the 'wheel' group in /etc/gshadow but not in /etc/group`
#      —— userdel -r alarm 清了 /etc/passwd 和 /etc/group，但 /etc/gshadow 里
#      的 wheel 成员还留着。删用户**之前**先 gpasswd -d alarm wheel，删完再兜底清一遍。
#   2) cfg80211: failed to load regulatory.db
#      —— rootfs 缺 wireless-regdb（提供 /lib/firmware/regulatory.db），会掉 5GHz 信道
#      与发射功率限制。这里直接装包，装不上就从宿主拷一份。
#   3) systemd-modules-load: Failed to find module 'crypto_user'
#      —— 该模块历史上是 =m 而构建流程不编模块。装了内核模块就好；顺手做一次校验。
#   4) USB 串口调试（USB gadget）
#      —— 把 usb-debug/usb-gadget/ 下的 configfs 绑定脚本 + systemd 常驻服务 +
#      udev 规则 + usb0 的 NetworkManager 连接铺进 rootfs。
#      刻意**不** enable serial-getty@ttyGS0：ttyGS0 要等 gadget 绑定后才存在，
#      开机无条件拉起会 device not found；交给 udev 规则按需启动。
#
#  ---------------------------------------------------------------------------
#  产物（带「构建时间戳」，多次构建不互相覆盖）
#    ~/xaga/rootfs-<distro>-<戳>.img          完整 ext4（本地想 dd / 挂载看时用）
#    ~/xaga/rootfs-<distro>-<戳>-sparse.img   fastboot 刷机用这个（传输快得多）
#    时间戳格式 YYYYmmdd-HHMMSS，与 build-mainline.sh 的 boot-<戳>.img 一致。
#    想固定名字：STAMP=20260920-1046 sudo -E ./build-rootfs.sh -d arch
#    或直接 -o /path/to/rootfs.img
#
#  ---------------------------------------------------------------------------
#  用法（必须 root）
#    sudo ./build-rootfs.sh -d arch                              # Arch Linux ARM（作者同款）
#    sudo ./build-rootfs.sh -d debian -r bookworm                # Debian 12
#    sudo ./build-rootfs.sh -d ubuntu -r resolute                # Ubuntu 26.04 LTS
#    sudo ./build-rootfs.sh -d arch -k ~/xaga/linux -m ~/xaga/out/modules.tar.gz
#    sudo ./build-rootfs.sh -d arch --ssid "iQOO Neo11" --psk password
#    sudo ./build-rootfs.sh --help
# =============================================================================
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 默认值
# ---------------------------------------------------------------------------
DISTRO=arch
RELEASE=""
SIZE=6G
ROOTPW=root
TARGET_HOSTNAME=xaga
MAKE_SPARSE=1
TOOL=auto
COMPONENTS=""
MIRROR=""
OUT=""
ROOT_DEV=/dev/sdc86
KDIR=""
MODULES_TAR=""
WITH_USB_GADGET=1
SSID=""
PSK=""

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KDIR_DEFAULT="$HOME/xaga/linux"
WORKDIR="$HOME/xaga/rootfs-dir"
IMG=""

usage() {
  cat <<'USAGE'
用法: sudo ./build-rootfs.sh [选项]

  -d, --distro <name>    发行版: arch | debian | ubuntu        (默认 arch)
  -r, --release <ver>    版本代号，省略用默认值:
                           arch   -> latest
                           debian -> bookworm  (也可 trixie / sid)
                           ubuntu -> resolute  (也可 noble / questing)
  -s, --size <size>      初始镜像大小                            (默认 6G)
  -o, --out <path>       输出镜像路径  (默认 ~/xaga/rootfs-<distro>-<时间戳>.img)
                         想固定名字: STAMP=20260920-1046 sudo -E ./build-rootfs.sh -d arch
  -w, --work <dir>       工作目录      (默认 ~/xaga/rootfs-dir)
  -k, --kernel <dir>     内核源码目录  (装了它就能编模块注入，默认 ~/xaga/linux)
  -m, --modules <tar>    直接指定 modules.tar.gz（build-mainline.sh 的产物）
      --no-modules       跳过内核模块注入（rootfs 会没有 /lib/modules）
      --no-usb-gadget    不铺 USB 串口调试那一套文件
      --ssid <ssid>      预置 WiFi SSID（NetworkManager，开机自动连）
      --psk <pass>       预置 WiFi 密码
  -e, --rootdev <dev>    rootfs 所在分区设备节点                   (默认 /dev/sdc86)
  -p, --password <pw>    root 密码                                (默认 root)
  -n, --hostname <name>  主机名                                   (默认 xaga)
  -t, --tool <tool>      debootstrap | mmdebstrap   (仅 debian/ubuntu)
      --mirror <url>     镜像站（默认国内源）
      --no-sparse        不生成 sparse 镜像
  -h, --help             显示本帮助

示例:
  sudo ./build-rootfs.sh -d arch
  sudo ./build-rootfs.sh -d arch -m ~/xaga/out/modules.tar.gz
  sudo ./build-rootfs.sh -d ubuntu -r resolute -s 8G -p 1234
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -d|--distro)     DISTRO=${2:?缺少参数}; shift 2;;
    -r|--release)    RELEASE=${2:?缺少参数}; shift 2;;
    -s|--size)       SIZE=${2:?缺少参数}; shift 2;;
    -o|--out)        OUT=${2:?缺少参数}; shift 2;;
    -w|--work)       WORKDIR=${2:?缺少参数}; shift 2;;
    -k|--kernel)     KDIR=${2:?缺少参数}; shift 2;;
    -m|--modules)    MODULES_TAR=${2:?缺少参数}; shift 2;;
    --no-modules)    MODULES_TAR=/dev/null; shift;;
    --no-usb-gadget) WITH_USB_GADGET=0; shift;;
    --ssid)          SSID=${2:?缺少参数}; shift 2;;
    --psk)           PSK=${2:?缺少参数}; shift 2;;
    -e|--rootdev)    ROOT_DEV=${2:?缺少参数}; shift 2;;
    -p|--password)   ROOTPW=${2:?缺少参数}; shift 2;;
    -n|--hostname)   TARGET_HOSTNAME=${2:?缺少参数}; shift 2;;
    -t|--tool)       TOOL=${2:?缺少参数}; shift 2;;
    --mirror)        MIRROR=${2:?缺少参数}; shift 2;;
    --no-sparse)     MAKE_SPARSE=0; shift;;
    -h|--help)       usage; exit 0;;
    *) echo "未知参数: $1" >&2; usage; exit 1;;
  esac
done

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 发行版相关默认值
# ---------------------------------------------------------------------------
case "$DISTRO" in
  arch|archlinux|archarm)
    DISTRO=arch
    RELEASE=${RELEASE:-latest}
    MIRROR=${MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/os/}
    ARCH_TARBALL="ArchLinuxARM-aarch64-${RELEASE}.tar.gz"
    ;;
  debian)
    RELEASE=${RELEASE:-bookworm}
    MIRROR=${MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/debian/}
    # firmware-mediatek 在 non-free-firmware 里，不加这个组件 WiFi/蓝牙就没固件
    COMPONENTS=${COMPONENTS:-main,non-free-firmware}
    [ "$TOOL" = auto ] && TOOL=debootstrap
    ;;
  ubuntu)
    RELEASE=${RELEASE:-resolute}
    MIRROR=${MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/}
    COMPONENTS=${COMPONENTS:-main,universe,multiverse,restricted}
    [ "$TOOL" = auto ] && TOOL=debootstrap
    ;;
  *) die "不支持的发行版: $DISTRO（可选 arch / debian / ubuntu）";;
esac

# 产物时间戳：内核侧（build-mainline.sh）用的是同一套格式，两边产物名风格一致。
# 想固定名字：STAMP=20260920-1046 sudo -E ./build-rootfs.sh -d arch
STAMP="${STAMP:-$(date +%Y%m%d-%H%M%S)}"
IMG=${OUT:-$HOME/xaga/rootfs-${DISTRO}-${STAMP}.img}
[ -n "$KDIR" ] || KDIR="$KDIR_DEFAULT"

log "时间戳 : $STAMP"
log "发行版 : $DISTRO $RELEASE"
log "镜像站 : $MIRROR"
log "镜像   : $IMG ($SIZE)"
log "工作区 : $WORKDIR"
log "root 分区: $ROOT_DEV"
log "内核树 : $KDIR"

# ---------------------------------------------------------------------------
# 前置检查
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "请用 sudo 运行（bootstrap / chroot / mkfs 都需要 root）"

command -v apt-get >/dev/null 2>&1 && \
  apt-get install -y -qq --no-install-recommends \
    qemu-user-static binfmt-support e2fsprogs curl ca-certificates kmod 2>/dev/null || true

QEMU=/usr/bin/qemu-aarch64-static
[ -f "$QEMU" ] || die "缺少 $QEMU，请先: apt-get install -y qemu-user-static"

# debootstrap 只认 /usr/share/debootstrap/scripts/ 里存在的 suite 名。
# 在旧主机上装新发行版（如 24.04 上做 26.04 resolute）会报 "no such script"，
# 这里拿机器上一个可用脚本顶替。
ensure_suite_script() {
  local s=$1 dir=/usr/share/debootstrap/scripts cand
  [ -e "$dir/$s" ] && return 0
  for cand in resolute questing plucky oracular noble jammy trixie bookworm sid; do
    if [ -e "$dir/$cand" ]; then
      warn "debootstrap 没有 '$s' 脚本，用 '$cand' 的顶替"
      ln -sf "$dir/$cand" "$dir/$s"
      return 0
    fi
  done
  return 1
}

# chroot 包装：优先 binfmt，没注册就显式调 qemu
CHROOT=()
setup_chroot_cmd() {
  if [ -d /proc/sys/fs/binfmt_misc ] && [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    log "binfmt 已注册，直接 chroot"
    CHROOT=(chroot "$WORKDIR")
  else
    warn "binfmt 未注册（容器/云主机常见），改用显式 qemu 解释器"
    CHROOT=(chroot "$WORKDIR" /usr/bin/qemu-aarch64-static)
  fi
}

# ---------------------------------------------------------------------------
# 1. bootstrap
# ---------------------------------------------------------------------------
if [ -x "$WORKDIR/bin/sh" ] || [ -x "$WORKDIR/usr/bin/env" ]; then
  log "检测到已存在的 rootfs 目录，跳过 bootstrap（想重来请 rm -rf $WORKDIR）"
else
  mkdir -p "$WORKDIR"

  case "$DISTRO" in
  arch)
    log "下载 Arch Linux ARM aarch64 tarball"
    command -v bsdtar >/dev/null || apt-get install -y -qq libarchive-tools 2>/dev/null || true
    cd "$(dirname "$WORKDIR")"
    if [ ! -f "$ARCH_TARBALL" ]; then
      curl -fL -O "${MIRROR}${ARCH_TARBALL}" \
        || die "下载失败。官方源: http://os.archlinuxarm.org/os/${ARCH_TARBALL}"
    fi
    log "解压 $(basename "$ARCH_TARBALL")"
    if command -v bsdtar >/dev/null; then
      bsdtar -xpf "$ARCH_TARBALL" -C "$WORKDIR"     # 保留 xattr / capabilities
    else
      warn "没装 bsdtar，退回 tar（capabilities 可能丢失）"
      tar -xpf "$ARCH_TARBALL" -C "$WORKDIR"
    fi
    ;;
  debian|ubuntu)
    ensure_suite_script "$RELEASE" || die "找不到 $RELEASE 的 debootstrap 脚本"
    if [ "$TOOL" = mmdebstrap ]; then
      command -v mmdebstrap >/dev/null || die "TOOL=mmdebstrap 但没装: apt-get install -y mmdebstrap"
      log "mmdebstrap $RELEASE/arm64 -> $WORKDIR"
      mmdebstrap --architecture=arm64 --variant=minbase \
                 --components="$COMPONENTS" \
                 "$RELEASE" "$WORKDIR" "$MIRROR"
    else
      log "debootstrap $RELEASE/arm64 -> $WORKDIR"
      debootstrap --arch=arm64 --foreign --components="$COMPONENTS" \
                  "$RELEASE" "$WORKDIR" "$MIRROR"
    fi
    ;;
  esac
fi

# 公共准备：qemu + DNS + proc/sys
cp -f "$QEMU" "$WORKDIR/usr/bin/" 2>/dev/null || true
rm -f "$WORKDIR/etc/resolv.conf"
cp /etc/resolv.conf "$WORKDIR/etc/resolv.conf" 2>/dev/null || true
mkdir -p "$WORKDIR/proc" "$WORKDIR/sys"
mountpoint -q "$WORKDIR/proc" || mount -t proc  proc  "$WORKDIR/proc" 2>/dev/null || true
mountpoint -q "$WORKDIR/sys"  || mount -t sysfs sysfs "$WORKDIR/sys"  2>/dev/null || true

setup_chroot_cmd

# debootstrap --foreign 需要 second-stage；mmdebstrap 与 Arch 一次到位
if [ -d "$WORKDIR/debootstrap" ] && [ "$TOOL" != mmdebstrap ]; then
  log "second-stage（qemu 下跑，比较慢，耐心等）"
  "${CHROOT[@]}" /bin/sh -c "/debootstrap/debootstrap --second-stage" || {
    warn "second-stage 返回非零，检查 $WORKDIR/debootstrap/ 下的日志"
    [ -n "${STRICT:-}" ] && exit 1
  }
fi

# ---------------------------------------------------------------------------
# 2. 通用配置
# ---------------------------------------------------------------------------
log "写通用配置（hostname / hosts / fstab）"
printf '%s\n' "$TARGET_HOSTNAME" > "$WORKDIR/etc/hostname"
cat > "$WORKDIR/etc/hosts" <<EOF
127.0.0.1       localhost
127.0.1.1       $TARGET_HOSTNAME
::1             localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF
# --- pacman.conf 替换（仅 Arch） --------------------------------------------
# 注意：必须在 chroot 里跑 pacman-key --init / pacman -Syu 之前完成。
# pacman.new.conf 相对原版做了两处关键调整：
#   * 打开 DisableSandboxFilesystem / DisableSandboxSyscalls
#     —— 在 qemu-user-static 用户态模拟下，pacman 的 seccomp/landlock 沙箱
#        无法正常工作，会直接拒绝启动或下载（Alarm 沙箱报 Operation not permitted）。
#   * 关闭 CheckSpace
#     —— 构建期镜像大小尚未真正占满、且 sparse 之前 free space 检测会误判。
if [ "$DISTRO" = arch ]; then
  PACMAN_NEW_CONF="$REPO_ROOT/pacman.conf"
  if [ -f "$PACMAN_NEW_CONF" ]; then
    cp -f "$PACMAN_NEW_CONF" "$WORKDIR/etc/pacman.conf"
    log "已用 pacman.new.conf 覆盖 /etc/pacman.conf（关沙箱 / 关 CheckSpace）"
  else
    warn "找不到 $PACMAN_NEW_CONF，保留 tarball 自带的 pacman.conf"
    warn "  qemu 下若 pacman 报沙箱错误，请手动设 DisableSandboxFilesystem/DisableSandboxSyscalls"
  fi
fi
# root 必须指向 initramfs 找的那个分区节点，否则 systemd 会认为 rootfs 不匹配
cat > "$WORKDIR/etc/fstab" <<EOF
# <device>        <mount>  <type>  <options>                          <dump> <pass>
$ROOT_DEV         /        ext4    defaults,noatime,errors=remount-ro  0      1
EOF

# 密码走文件，避免 heredoc 里的引号地狱
printf 'root:%s\n' "$ROOTPW" > "$WORKDIR/rootpw.txt"

# 预置 WiFi 连接（可选）
NM_DIR="$WORKDIR/etc/NetworkManager/system-connections"
if [ -n "$SSID" ]; then
  mkdir -p "$NM_DIR"
  cat > "$NM_DIR/xaga-wifi.nmconnection" <<EOF
[connection]
id=xaga-wifi
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=$SSID

[wifi-security]
key-mgmt=wpa-psk
psk=$PSK

[ipv4]
method=auto

[ipv6]
method=auto
EOF
  chmod 600 "$NM_DIR/xaga-wifi.nmconnection"
  log "已预置 WiFi: $SSID"
fi

log "安装软件包并配置服务（$DISTRO）"
case "$DISTRO" in
arch)
  cat > "$WORKDIR/configure.sh" <<'EOS'
set -e
pacman-key --init
pacman-key --populate archlinuxarm

# 用我们自己编的内核，去掉 tarball 自带的（省 ~100MB，也免得混淆）
pacman -Rdd --noconfirm linux-aarch64 2>/dev/null || true

# ⚠️ shadow.service 开机失败的根因就在这两行之间：
#    userdel 只清 /etc/passwd + /etc/group，/etc/gshadow 里的 wheel 成员会留下来。
#    所以必须先 gpasswd -d alarm wheel 再删。
if id alarm >/dev/null 2>&1; then
  gpasswd -d alarm wheel 2>/dev/null || true
  for g in wheel users tty uucp; do gpasswd -d alarm "$g" 2>/dev/null || true; done
  userdel -r alarm 2>/dev/null || true
fi
# 兜底：把 /etc/gshadow 里任何残留的 alarm 成员清掉（不影响其它组）
if [ -f /etc/gshadow ]; then
  sed -i 's/\balarm\b//g' /etc/gshadow
fi

pacman -Syu --noconfirm

# 基础系统
pacman -S --noconfirm --needed \
  networkmanager iwd openssh sudo vim less curl wget ca-certificates \
  usbutils kmod 2>/dev/null || \
pacman -S --noconfirm --needed \
  networkmanager iwd openssh sudo vim less curl wget ca-certificates

# 固件：mediatek 包缺了 WiFi/蓝牙/声卡/触控全废；
# wireless-regdb 缺了内核会报 "cfg80211: failed to load regulatory.db"
pacman -S --noconfirm --needed linux-firmware-mediatek || true
pacman -S --noconfirm --needed wireless-regdb || true

sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/'   /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
ssh-keygen -A

systemctl enable NetworkManager
systemctl enable sshd
systemctl enable systemd-resolved
systemctl enable getty@tty1

cat /rootpw.txt | chpasswd
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
EOS
  ;;
debian|ubuntu)
  cat > "$WORKDIR/configure.sh" <<'EOS'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# 确保 non-free-firmware 可用（Debian 12 起固件被拆到独立组件）
if [ -f /etc/apt/sources.list ]; then
  if ! grep -q non-free-firmware /etc/apt/sources.list; then
    sed -i 's/^\(deb .*main\)$/\1 contrib non-free non-free-firmware/' /etc/apt/sources.list || true
    apt-get update -qq || true
  fi
fi

apt-get install -y -qq --no-install-recommends \
  systemd-sysv dbus \
  network-manager iwd wpasupplicant \
  openssh-server sudo \
  usbutils kmod \
  ca-certificates curl wget less vim-tiny

# 固件：缺了 WiFi/蓝牙/声卡/触控全废
apt-get install -y -qq --no-install-recommends firmware-mediatek 2>/dev/null || \
  apt-get install -y -qq --no-install-recommends linux-firmware 2>/dev/null || \
  echo "[!] 没装上 mediatek 固件，请自行补齐 /lib/firmware/mediatek"

# 内核会报 "cfg80211: failed to load regulatory.db"（掉 5GHz / 功率限制）
apt-get install -y -qq --no-install-recommends wireless-regdb 2>/dev/null || true

# 清掉可能存在的普通用户，避免 gshadow / group 不一致（同 Arch 那套道理）
if id alarm >/dev/null 2>&1; then
  gpasswd -d alarm wheel 2>/dev/null || true
  userdel -r alarm 2>/dev/null || true
fi
[ -f /etc/gshadow ] && sed -i 's/\balarm\b//g' /etc/gshadow

sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/'   /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
ssh-keygen -A

systemctl enable ssh
systemctl enable NetworkManager
systemctl enable systemd-resolved
systemctl enable getty@tty1

cat /rootpw.txt | chpasswd
echo "Asia/Shanghai" > /etc/timezone
rm -f /etc/localtime
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
EOS
  ;;
esac

"${CHROOT[@]}" /bin/sh /configure.sh || warn "配置阶段有命令失败，请人工检查（不致命）"
rm -f "$WORKDIR/configure.sh" "$WORKDIR/rootpw.txt"

# 固件兜底：从宿主拷 regulatory.db（wireless-regdb 装不上时）
if [ ! -e "$WORKDIR/lib/firmware/regulatory.db" ]; then
  for cand in /lib/firmware/regulatory.db /usr/lib/firmware/regulatory.db; do
    if [ -f "$cand" ]; then
      warn "rootfs 缺 regulatory.db，从宿主拷 $cand"
      mkdir -p "$WORKDIR/lib/firmware"
      cp -f "$cand" "$WORKDIR/lib/firmware/"
      [ -f "${cand}.p7s" ] && cp -f "${cand}.p7s" "$WORKDIR/lib/firmware/" || true
      break
    fi
  done
fi

# initramfs 会把 nvdata 里的固件 mirror 到 /lib/firmware/mediatek/mt6895，目录先建好
mkdir -p "$WORKDIR/lib/firmware/mediatek/mt6895"

# 日志里 `systemd-modules-load: Failed to find module 'crypto_user'` 的修法：
# CONFIG_CRYPTO_USER 是编译进内核的（=y），没有 .ko 文件；但 rootfs 里有
# modules-load.d 的 drop-in 在开机时 modprobe 它，modprobe 找不到文件就报错。
# 直接把这条 drop-in 里的 crypto_user 删掉即可。
CLEANED=0
for d in "$WORKDIR/etc/modules-load.d" "$WORKDIR/usr/lib/modules-load.d" \
         "$WORKDIR/lib/modules-load.d"; do
  [ -d "$d" ] || continue
  if grep -rqs '^crypto_user$' "$d"; then
    find "$d" -name '*.conf' -exec sed -i '/^crypto_user$/d' {} +
    CLEANED=1
  fi
done
[ "$CLEANED" = 1 ] && log "已清理 modules-load.d 里内建模块 crypto_user 的加载项"

# ---------------------------------------------------------------------------
# 3. 内核模块注入
# ---------------------------------------------------------------------------
MODULES_INSTALLED=0
if [ "$MODULES_TAR" != "/dev/null" ]; then
  TMPMOD=""
  if [ -n "$MODULES_TAR" ] && [ -f "$MODULES_TAR" ]; then
    TMPMOD="$MODULES_TAR"
  elif [ -f "$KDIR/vmlinux" ] && [ -d "$KDIR/scripts" ]; then
    log "从内核树 $KDIR 编并安装模块"
    KVER=$(make -s -C "$KDIR" ARCH=arm64 kernelrelease)
    log "内核版本: $KVER"
    make -C "$KDIR" ARCH=arm64 LLVM=1 -j"$(nproc)" modules >/dev/null 2>&1 || \
      warn "make modules 有失败（不致命）"
    make -C "$KDIR" ARCH=arm64 LLVM=1 \
         modules_install INSTALL_MOD_PATH="$WORKDIR" INSTALL_MOD_STRIP=1 DEPMOD=true || \
      warn "modules_install 失败"
    MODULES_INSTALLED=1
  fi

  if [ -n "$TMPMOD" ]; then
    log "解压模块包 $TMPMOD -> $WORKDIR"
    tar -xzf "$TMPMOD" -C "$WORKDIR"
    MODULES_INSTALLED=1
  fi

  if [ "$MODULES_INSTALLED" = 1 ] && [ -d "$WORKDIR/lib/modules" ]; then
    # 必须用目标架构的 depmod：宿主 x86 的 depmod 生成的 modules.dep 设备上读不了
    KVER_DIR=$(ls -1 "$WORKDIR/lib/modules" | head -1)
    "${CHROOT[@]}" /bin/sh -c "depmod -a '$KVER_DIR'" 2>/dev/null \
      || warn "chroot 里 depmod 失败；开机后手动跑: depmod -a $KVER_DIR"
    # modules.dep 存在才算真装好（日志里 modules.devname 找不到就是这个原因）
    if [ -f "$WORKDIR/lib/modules/$KVER_DIR/modules.dep" ]; then
      log "内核模块就绪: $KVER_DIR（$(find "$WORKDIR/lib/modules/$KVER_DIR" -name '*.ko*' | wc -l) 个）"
    else
      warn "modules.dep 缺失，/lib/modules/$KVER_DIR 可能不完整"
    fi
  else
    warn "没有可用的内核模块（rootfs 将没有 /lib/modules；=m 的驱动全都不工作）"
    warn "  先跑 build-mainline.sh（默认 BUILD_MODULES=1）再用 -m 指过来，或 -k 指内核树"
  fi
fi

# ---------------------------------------------------------------------------
# 4. USB 串口调试（gadget）
# ---------------------------------------------------------------------------
if [ "$WITH_USB_GADGET" = "1" ]; then
  SRC="$REPO_ROOT/usb-debug/usb-gadget"
  if [ -d "$SRC" ]; then
    log "铺 USB gadget 调试文件 -> rootfs"
    cp -a "$SRC/." "$WORKDIR/"
    chmod 755 "$WORKDIR/usr/local/sbin/xaga-usb-gadget" 2>/dev/null || true
    chmod 644 "$WORKDIR/etc/systemd/system/xaga-usb-gadget.service" 2>/dev/null || true
    chmod 644 "$WORKDIR/etc/udev/rules.d/91-xaga-usb-serial.rules" 2>/dev/null || true
    # 用软链接完成自启（不进 chroot，快且不依赖 systemctl 可用）
    mkdir -p "$WORKDIR/etc/systemd/system/multi-user.target.wants"
    ln -sf /etc/systemd/system/xaga-usb-gadget.service \
           "$WORKDIR/etc/systemd/system/multi-user.target.wants/xaga-usb-gadget.service"
    # 刻意不 enable serial-getty@ttyGS0 —— ttyGS0 要等 gadget 绑定后才存在，
    # 开机无条件拉起会 device not found，交给 udev 规则按需启动。
    rm -f "$WORKDIR/etc/systemd/system/getty.target.wants/serial-getty@ttyGS0.service"
    [ -f "$NM_DIR/xaga-usb0.nmconnection" ] && chmod 600 "$NM_DIR/xaga-usb0.nmconnection"
    log "  已装：xaga-usb-gadget（服务+脚本）、91-xaga-usb-serial.rules、xaga-usb0.nmconnection"
  else
    warn "找不到 $SRC，跳过 USB gadget 文件"
  fi
fi

# ---------------------------------------------------------------------------
# 5. /sbin/init 兜底 —— init.c 写死了 execve("/sbin/init")，缺了必黑屏
# ---------------------------------------------------------------------------
if [ ! -e "$WORKDIR/sbin/init" ]; then
  for c in /usr/lib/systemd/systemd /lib/systemd/systemd /usr/bin/systemd; do
    if [ -e "$WORKDIR$c" ]; then
      warn "/sbin/init 不存在，补一个 -> $c"
      mkdir -p "$WORKDIR/sbin"
      ln -sf "$c" "$WORKDIR/sbin/init"
      break
    fi
  done
fi
[ -e "$WORKDIR/sbin/init" ] || die "rootfs 里没有 /sbin/init！init.c 会 exec 失败然后死循环黑屏"

# 关键项体检
log "关键项体检"
for f in "$WORKDIR"/usr/lib/systemd/systemd "$WORKDIR"/usr/bin/nmcli \
         "$WORKDIR"/usr/sbin/sshd "$WORKDIR"/usr/local/sbin/xaga-usb-gadget; do
  [ -e "$f" ] && echo "    ok  ${f#"$WORKDIR"}" || echo "    --  ${f#"$WORKDIR"} (无)"
done
[ -d "$WORKDIR/lib/firmware/mediatek" ] && echo "    ok  /lib/firmware/mediatek" \
  || warn "  /lib/firmware/mediatek 不存在（WiFi/蓝牙固件可能不全）"
if [ -e "$WORKDIR/etc/gshadow" ] && grep -q 'alarm' "$WORKDIR/etc/gshadow"; then
  warn "/etc/gshadow 里仍有 alarm，正在清理（否则开机 shadow.service 会失败）"
  sed -i 's/\balarm\b//g' "$WORKDIR/etc/gshadow"
fi

# ---------------------------------------------------------------------------
# 6. 收尾并打包（用 mkfs.ext4 -d，不依赖 loop 设备）
# ---------------------------------------------------------------------------
log "收尾 -> $IMG"
umount -lf "$WORKDIR/proc" 2>/dev/null || true
umount -lf "$WORKDIR/sys"  2>/dev/null || true
rm -f "$WORKDIR/usr/bin/qemu-aarch64-static"
rm -rf "$WORKDIR/debootstrap" 2>/dev/null || true

mkdir -p "$(dirname "$IMG")"
rm -f "$IMG"
truncate -s "$SIZE" "$IMG"
# ^metadata_csum_seed：设备侧 e2fsprogs 可能较旧，关掉这个 feature 兼容性最好
mkfs.ext4 -F -L xaga-root -O ^metadata_csum_seed -d "$WORKDIR" "$IMG"
e2fsck -fy "$IMG" >/dev/null 2>&1 || true

if [ "$MAKE_SPARSE" = "1" ] && command -v img2simg >/dev/null; then
  log "生成 sparse 镜像（fastboot 传输快得多）"
  img2simg "$IMG" "${IMG%.img}-sparse.img"
  ls -lh "$IMG" "${IMG%.img}-sparse.img"
else
  [ "$MAKE_SPARSE" = "1" ] && \
    warn "没装 img2simg，跳过 sparse（apt-get install android-sdk-libsparse-utils）"
  ls -lh "$IMG"
fi

log "完成"
echo
echo "  发行版     : $DISTRO $RELEASE"
echo "  时间戳     : $STAMP"
echo "  镜像       : $IMG ($SIZE)"
echo "  rootfs 目录: $WORKDIR"
echo "  登录       : root / $ROOTPW"
echo "  root 分区  : $ROOT_DEV（必须与 initramfs 的 BOOT_PARTITION 一致）"
echo
echo "  开机后扩充分区: resize2fs $ROOT_DEV"
echo "  6+128 机型先确认: free -h    （实测日志已是 6291456K = 6GiB）"
echo
echo "  下一步:"
echo "    fastboot flash userdata ${IMG%.img}-sparse.img   # ⚠ 清空内置存储"
echo "    fastboot flash boot_a <build-mainline.sh 产出的 boot-<时间戳>.img>"
echo "    fastboot reboot"
