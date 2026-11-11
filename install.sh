#!/bin/sh
# Run INSIDE the chroot as root, after you have done by hand:
#   cfdisk, mkfs, mount (ESP on /boot), chimera-bootstrap, chimera-chroot
#
#   USERNAME=haadi HOSTNAME=chimera SWAP_DEV=/dev/sdX2 \
#   DOTFILES=https://github.com/you/tokyo-dotfiles.git sh install.sh
#
# SWAP_DEV and DOTFILES are optional.
# Package installs go one at a time; names that don't exist are listed at the end
# instead of aborting the run.

set -u
export GIT_TERMINAL_PROMPT=0   # a private/mistyped repo fails instead of waiting for a login

USERNAME="${USERNAME:-haadi}"
HOSTNAME="${HOSTNAME:-chimera}"
TZ_NAME="${TZ_NAME:-Europe/London}"
SWAP_DEV="${SWAP_DEV:-}"
DOTFILES="${DOTFILES:-}"

FAILED=""
die() { echo "error: $*" >&2; exit 1; }
# Every apk call reads from /dev/null so it never stops on a [Y/n] prompt.
add() {
  for p in "$@"; do
    apk add "$p" </dev/null || FAILED="$FAILED $p"
  done
}

[ "$(id -u)" -eq 0 ] || die "run as root inside the chroot"

# --- repos: main is default, add user + contrib -----------------------------
apk add chimera-repo-user chimera-repo-contrib </dev/null || die "could not add user/contrib repos"
apk update </dev/null
apk upgrade </dev/null

# --- detect devices, write fstab --------------------------------------------
ROOT_DEV=$(findmnt -no SOURCE / | sed 's/\[.*//')
ROOT_FS=$(findmnt -no FSTYPE /)
BOOT_DEV=$(findmnt -no SOURCE /boot | sed 's/\[.*//')
BOOT_FS=$(findmnt -no FSTYPE /boot)

[ -n "$ROOT_DEV" ] || die "cannot detect root device"
[ -n "$BOOT_DEV" ] || die "/boot is not mounted: mount the ESP on /boot before chimera-bootstrap"
[ "$BOOT_FS" = "vfat" ] || die "/boot is $BOOT_FS, expected vfat (the ESP)"

ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV")
BOOT_UUID=$(blkid -s UUID -o value "$BOOT_DEV")
echo "root: $ROOT_DEV ($ROOT_FS) $ROOT_UUID"
echo "esp:  $BOOT_DEV $BOOT_UUID"

ROOT_OPTS=defaults
[ "$ROOT_FS" = "btrfs" ] && ROOT_OPTS=defaults,compress=zstd

{
  echo "# <file system> <dir> <type> <options> <dump> <pass>"
  echo "UUID=$ROOT_UUID  /      $ROOT_FS  $ROOT_OPTS  0 0"
  echo "UUID=$BOOT_UUID  /boot  vfat  umask=0077  0 2"
  if [ -n "$SWAP_DEV" ]; then
    echo "UUID=$(blkid -s UUID -o value "$SWAP_DEV")  none  swap  defaults  0 0"
  fi
} > /etc/fstab
cat /etc/fstab

echo "$HOSTNAME" > /etc/hostname
ln -sf "/usr/share/zoneinfo/$TZ_NAME" /etc/localtime

# --- kernel + boot ----------------------------------------------------------
add linux-lts linux-lts-devel systemd-boot

# --- graphics: nouveau (kernel) + NVK (Vulkan) + Mesa GL --------------------
# nouveau is in the kernel; NVK ships inside mesa-vulkan (nouveau_icd.json).
# Turing and newer need the GSP firmware for nouveau to work.
add firmware-linux-nvidia firmware-linux-nvidia-gsp
add mesa mesa-vulkan vulkan-tools mesa-utils

# --- network, ssh, privilege, shell -----------------------------------------
add dhcpcd openssh doas zsh bash git rsync

# --- build deps for scenefx + mango -----------------------------------------
add clang meson ninja pkgconf
add wayland-devel wayland-protocols wlroots0.20-devel
add libinput-devel libxkbcommon-devel pixman-devel libdrm-devel mesa-devel
add libseat-devel libdisplay-info-devel hwdata xwayland
add cjson-devel pcre2-devel pango-devel cairo-devel

# --- desktop ----------------------------------------------------------------
add foot wmenu mako waybar
add pipewire wireplumber pipewire-pulse
add fonts-nerd-jetbrains-mono fonts-nerd-iosevka fonts-nerd-iosevka-term fonts-nerd-symbols-only
add papirus-icon-theme
fc-cache -f 2>/dev/null || true

# --- user -------------------------------------------------------------------
id "$USERNAME" >/dev/null 2>&1 || useradd -m -G wheel -s /usr/bin/zsh "$USERNAME"
echo 'permit persist keepenv :wheel' > /etc/doas.conf

# --- services (offline: dinit isn't running in a chroot) --------------------
dinitctl --offline enable dhcpcd
dinitctl --offline enable sshd

# --- scenefx + mango (not packaged for Chimera) -----------------------------
# musl has no __always_inline (glibc macro); BSD sed needs -i ''.
patch_inline() {
  grep -rl __always_inline "$1" 2>/dev/null | \
    xargs sed -i '' 's/__always_inline/inline __attribute__((always_inline))/g'
}
build() {
  name=$1; url=$2; branch=${3:-}
  cd /root
  mkdir -p src && cd src
  if [ ! -d "$name" ]; then
    if [ -n "$branch" ]; then git clone -b "$branch" "$url" "$name"; else git clone "$url" "$name"; fi
  fi
  cd "$name" || return 1
  patch_inline .
  rm -rf build
  meson setup build -Dprefix=/usr -Dwerror=false && ninja -C build && ninja -C build install \
    || FAILED="$FAILED build:$name"
}
build scenefx https://github.com/wlrfx/scenefx.git 0.5
build mango   https://github.com/mangowm/mango.git

# --- dotfiles (BSD cp has no --backup, so copy file by file) ----------------
backup_copy() {
  src=$1; dest=$2
  mkdir -p "$dest"
  (cd "$src" && find . \( -type f -o -type l \)) | while IFS= read -r f; do
    t="$dest/$f"
    mkdir -p "$(dirname "$t")"
    if [ -e "$t" ] || [ -L "$t" ]; then
      n=1
      while [ -e "$t.~$n~" ] || [ -L "$t.~$n~" ]; do n=$((n+1)); done
      mv "$t" "$t.~$n~"
    fi
    cp -P "$src/$f" "$t"
  done
}

UHOME="/home/$USERNAME"
if [ -n "$DOTFILES" ]; then
  mkdir -p "$UHOME/src"
  [ -d "$UHOME/src/dotfiles" ] || git clone "$DOTFILES" "$UHOME/src/dotfiles"
  for d in "$UHOME"/src/dotfiles/*/; do
    name=$(basename "$d")
    backup_copy "$d" "$UHOME/.config/$name" && echo "dotfiles: $name"
  done
fi

# pipewire etc. as user services, if the package ships them
mkdir -p "$UHOME/.config/dinit.d/boot.d"
for s in pipewire wireplumber pipewire-pulse; do
  for dir in /usr/lib/dinit.d/user /etc/dinit.d/user; do
    [ -e "$dir/$s" ] && ln -sf "$dir/$s" "$UHOME/.config/dinit.d/boot.d/$s" && break
  done
done
chown -R "$USERNAME:$USERNAME" "$UHOME"

# --- bootloader -------------------------------------------------------------
update-initramfs -c -k all
bootctl install
chmod 600 /boot/loader/random-seed 2>/dev/null || true

if ! ls /boot/loader/entries/*.conf >/dev/null 2>&1; then
  KVER=$(ls /boot | sed -n 's/^vmlinuz-//p' | head -n 1)
  [ -n "$KVER" ] || die "no kernel found in /boot"
  cat > /boot/loader/entries/chimera.conf <<EOF
title   Chimera Linux
linux   /vmlinuz-$KVER
initrd  /initrd.img-$KVER
options root=UUID=$ROOT_UUID rw
EOF
fi
bootctl list

# --- report -----------------------------------------------------------------
echo
if [ -n "$FAILED" ]; then
  echo "FAILED (check names with: apk search <word>):"
  for p in $FAILED; do echo "  $p"; done
else
  echo "Everything installed."
fi
command -v mango >/dev/null && echo "mango: $(command -v mango)" || echo "mango: NOT FOUND"

# --- passwords: the only interactive part, deliberately last ----------------
echo
echo "Set passwords (the last prompts):"
echo "Password for $USERNAME:"; passwd "$USERNAME" </dev/tty
echo "Password for root:";      passwd root </dev/tty

cat <<'EOF'

Next: exit; umount -R /media/root; reboot  (pick Linux Boot Manager)
Then on a TTY as your user: mango
Check NVK with:  vulkaninfo --summary | grep -i -E 'nouveau|NVK'
EOF
