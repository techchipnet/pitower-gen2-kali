#!/usr/bin/env bash
# PiTower Gen2 / Raspberry Pi 5 / Kali ARM64
set -Eeuo pipefail
VERSION=0.1.0-rc.1
umask 022
trap 'echo "FAILED at line $LINENO. Fix the error above, then rerun. Backups: ${backup:-not created}" >&2' ERR
REV=f3e5484984e18190f45e8daa9504e01b9e05bd07
APP=/opt/pitower-gen2
MODE=${1:-install}
[[ $# -le 1 ]] || { echo 'Expected at most one command.' >&2; exit 2; }
case "$MODE" in
    -h|--help|help)
        echo "PiTower Gen2 Kali installer $VERSION"
        echo "Usage: sudo bash $0 [install|status]"
        echo 'Install requires Raspberry Pi 5, Kali ARM64, Internet and systemd.'
        echo 'PITOWER_BOOT_CONFIG may override the active firmware config path.'
        exit 0 ;;
    --version) echo "$VERSION"; exit 0 ;;
    install|status) ;;
    *) echo "Unknown command: $MODE (use --help)" >&2; exit 2 ;;
esac
fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID == 0 ]] || fail "Run: sudo bash $0 ${1:-}"
units=(lcd_script.service rgb_control.service pitower-button.service)
if [[ $MODE == status ]]; then
    result=0
    systemctl --no-pager --full status "${units[@]}" || result=1
    ls -l /dev/spidev0.0 /dev/spidev1.0 /dev/i2c-0 /dev/gpiochip* 2>/dev/null || true
    journalctl -u lcd_script -u rgb_control -u pitower-button -n 60 --no-pager
    exit "$result"
fi
command -v flock >/dev/null || fail 'flock is required (install util-linux).'
exec 9>/run/lock/pitower-gen2-install.lock
flock -n 9 || fail 'Another PiTower installation is running.'
[[ ! -L $APP ]] || fail "$APP must not be a symlink."
if [[ -e $APP ]]; then
    [[ $(stat -c %u "$APP") == 0 ]] || fail "$APP must be owned by root."
    [[ -z $(find "$APP" -maxdepth 0 -perm /022 -print) ]] || fail "$APP must not be group/world writable."
fi
[[ -r /etc/os-release ]] || fail 'Missing /etc/os-release.'
# Read only the distro ID; do not execute /etc/os-release as shell code.
grep -Eq '^ID=("kali"|kali)$' /etc/os-release || fail 'This release targets Kali Linux only.'
# A vendor ExecStop hook can send power-management commands. Never stop it here.
for unit in shutdown.service rcshutdown.service; do
    if systemctl cat "$unit" 2>/dev/null | grep -E '/usr/local/bin/shutdownsignal.py|/etc/rc.shutdown' >/dev/null; then
        fail "Existing vendor $unit detected. See README migration guidance before installing."
    fi
done
[[ -r /proc/device-tree/model ]] || fail 'Run on the Raspberry Pi itself.'
model=$(tr -d '\0' < /proc/device-tree/model)
[[ $model == *'Raspberry Pi 5'* ]] || fail "Only Pi 5 supported; detected: $model"
[[ $(dpkg --print-architecture) == arm64 ]] || fail '64-bit ARM Kali required.'
[[ -d /run/systemd/system ]] || fail 'A systemd installation is required.'
# Firmware paths differ between Kali images. An explicit override is available.
cfg=${PITOWER_BOOT_CONFIG:-}
if [[ -z $cfg ]]; then
    if [[ -f /boot/firmware/config.txt ]]; then cfg=/boot/firmware/config.txt
    elif [[ -f /boot/config.txt ]]; then cfg=/boot/config.txt
    else fail 'No firmware config found. Set PITOWER_BOOT_CONFIG to the active config.txt.'; fi
fi
[[ -f $cfg ]] || fail "Not a file: $cfg"
# Validate overlays before changing anything.
overlay_dir="$(dirname "$cfg")/overlays"
for overlay in i2c0 spi1-3cs; do
    [[ -f $overlay_dir/$overlay.dtbo ]] || fail "Missing $overlay_dir/$overlay.dtbo; install the correct Kali Raspberry Pi firmware first."
done
install -d -m 0700 /var/log/pitower-gen2
log=/var/log/pitower-gen2/install-$(date +%Y%m%d-%H%M%S)-$$.log
exec > >(tee -a "$log") 2>&1
echo "PiTower installer $VERSION; log: $log"
backup=/var/backups/pitower-gen2/$(date +%Y%m%d-%H%M%S)-$$
mkdir -p "$backup"
chmod 0700 "$backup"
# Save the module-loader file and previous service state for manual recovery.
if [[ -f /etc/modules-load.d/pitower-gen2.conf ]]; then
    cp -a /etc/modules-load.d/pitower-gen2.conf "$backup/modules-load.conf"
fi
for unit in "${units[@]}"; do
    printf '%s enabled=%s active=%s\n' "$unit" \
        "$(systemctl is-enabled "$unit" 2>/dev/null || true)" \
        "$(systemctl is-active "$unit" 2>/dev/null || true)" >> "$backup/service-state.txt"
done
cp -L --preserve=mode,ownership,timestamps "$cfg" "$backup/config.txt"
printf '%s\n' "$cfg" > "$backup/config-path.txt"
for unit in "${units[@]}"; do
    if [[ -f /etc/systemd/system/$unit ]]; then cp -a "/etc/systemd/system/$unit" "$backup/"; fi
done
if [[ -e $APP ]]; then cp -a "$APP" "$backup/app"; fi
apt-get update
apt-get install -y git ca-certificates python3 python3-pil python3-numpy \
    python3-spidev python3-psutil python3-smbus python3-venv \
    fonts-dejavu-core kmod
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
git -C "$stage" init -q
git -C "$stage" remote add origin https://github.com/Elecrow-RD/PiTower_Gen2.git
git -C "$stage" fetch --depth 1 origin "$REV"
git -C "$stage" checkout --detach FETCH_HEAD
[[ $(git -C "$stage" rev-parse HEAD) == "$REV" ]] || fail 'Source revision mismatch.'
# Do not replace a running program underneath its interpreter.
for unit in "${units[@]}"; do systemctl stop "$unit" 2>/dev/null || true; done
install -d "$APP"
cp -a "$stage/Pictures" "$stage/LCD_Module_RPI_code" "$APP/"
install -m 0644 "$stage/lcd_display.py" "$stage/rgb_control.py" "$APP/"
cp -a "$stage/LCD_Module_RPI_code/RaspberryPi/python/lib/"*.py "$APP/"
cp -a "$stage/RGB_Module_RPI_code/rpi5_ws2812" "$APP/"
find "$APP" -type d -name __pycache__ -prune -exec rm -rf {} +
printf '%s\n' "$REV" > "$APP/UPSTREAM_REVISION"
# Own modules stay local; Kali's managed Python directories are not modified.
cat > "$APP/button.py" <<'PY'
import logging
import subprocess
import time
import smbus
logging.basicConfig(level=logging.INFO, format='%(asctime)s %(message)s')
bus = smbus.SMBus(0)
errors = 0
while True:
    try:
        requested = bus.read_byte_data(0x2D, 0xFF) == 0
        errors = 0
        if requested:
            # Debounce; let Linux shut down before any manual power removal.
            time.sleep(0.1)
            if bus.read_byte_data(0x2D, 0xFF) == 0:
                logging.info('PiTower button: requesting orderly poweroff')
                subprocess.run(['/usr/bin/systemctl', 'poweroff'], check=True)
                time.sleep(60)
    except OSError as exc:
        errors += 1
        if errors == 1 or errors % 60 == 0:
            logging.warning('I2C controller unavailable: %s', exc)
    time.sleep(0.25)
PY
# Use a private environment so pip never changes Kali's system Python.
python3 -m venv --system-site-packages "$APP/venv"
PYTHON="$APP/venv/bin/python"
if apt-cache policy python3-lgpio | grep -E 'Candidate: [^ (]' >/dev/null; then
    apt-get install -y python3-lgpio
fi
if ! "$PYTHON" -c 'import lgpio' 2>/dev/null; then
    echo 'python3-lgpio unavailable; installing lgpio into the private environment.'
    apt-get install -y build-essential python3-dev swig
    # Build just the native library from the pinned upstream source. Keep it
    # inside this application; do not run upstream's system-wide make install.
    lg_rev=bcccd782eceedc5b278b3056ea81d5fbbb89c489
    lg_src="$stage/lg-native"
    git init -q "$lg_src"
    git -C "$lg_src" remote add origin https://github.com/joan2937/lg.git
    git -C "$lg_src" fetch --depth 1 origin "$lg_rev"
    git -C "$lg_src" checkout --detach FETCH_HEAD
    [[ $(git -C "$lg_src" rev-parse HEAD) == "$lg_rev" ]] || fail 'lgpio source revision mismatch.'
    make -C "$lg_src" -j2 liblgpio.so
    install -d "$APP/native/lib" "$APP/native/include"
    install -m 0755 "$lg_src/liblgpio.so.1" "$APP/native/lib/liblgpio.so.1"
    ln -sfn liblgpio.so.1 "$APP/native/lib/liblgpio.so"
    install -m 0644 "$lg_src/lgpio.h" "$APP/native/include/lgpio.h"
    printf '%s\n' "$lg_rev" > "$APP/native/UPSTREAM_REVISION"
    "$PYTHON" -c "import ctypes; ctypes.CDLL('$APP/native/lib/liblgpio.so.1'); print('Native liblgpio: OK')"
    # lgpio's SWIG typemaps still use Python 2 C-API names. New SWIG
    # versions no longer supply those compatibility aliases. Map them to
    # the Python 3 APIs explicitly; do not suppress compiler diagnostics.
    lgpio_compat_flags='-DPyInt_FromLong=PyLong_FromLong -DPyInt_AsLong=PyLong_AsLong -DPyInt_Check=PyLong_Check -DPyString_FromString=PyUnicode_FromString'
    CFLAGS="${CFLAGS:-} $lgpio_compat_flags -I$APP/native/include" \
    LDFLAGS="${LDFLAGS:-} -L$APP/native/lib -Wl,-rpath,$APP/native/lib" \
        "$PYTHON" -m pip install --no-cache-dir --no-binary=lgpio lgpio==0.2.2.0
    "$PYTHON" -c 'import lgpio; print("lgpio native extension: OK")'
fi
# Recent GPIO Zero releases contain the Pi 5 pin-factory fixes.
"$PYTHON" -m pip install 'gpiozero==2.0.1.post3' 'colorzero==2.0'
# Reject syntax errors without importing drivers (imports can open hardware).
"$PYTHON" -m py_compile "$APP/lcd_display.py" "$APP/rgb_control.py" "$APP/button.py" "$APP/lcdconfig.py" "$APP/LCD_2inch8.py"
"$PYTHON" -c 'import PIL, numpy, spidev, psutil, smbus, gpiozero, lgpio'
"$PYTHON" -m pip freeze > "$APP/python-packages.txt"
printf '%s\n' "$VERSION" > "$APP/INSTALLER_VERSION"
for entry in lcd_script:lcd_display rgb_control:rgb_control pitower-button:button; do
    unit=${entry%%:*}; script=${entry#*:}
    cat > "/etc/systemd/system/$unit.service" <<EOF
[Unit]
Description=PiTower Gen2 $unit
After=systemd-modules-load.service
StartLimitIntervalSec=120
StartLimitBurst=6
[Service]
Type=simple
User=root
WorkingDirectory=$APP
Environment=GPIOZERO_PIN_FACTORY=lgpio
Environment=PYTHONUNBUFFERED=1
Environment=TERM=dumb
ExecStart=$PYTHON $APP/$script.py
Restart=on-failure
RestartSec=10
TimeoutStopSec=15
[Install]
WantedBy=multi-user.target
EOF
done
# Scope to all models; remove only our own previous managed block.
python3 - "$cfg" <<'PY'
from pathlib import Path
import re
import sys
import os
import shutil
import tempfile
p = Path(sys.argv[1]).resolve()
s = p.read_text()
s = re.sub(r'\n?# BEGIN PITOWER GEN2\n.*?# END PITOWER GEN2\n?', '', s, flags=re.S)
s += '\n# BEGIN PITOWER GEN2\n[all]\ndtoverlay=i2c0\ndtparam=spi=on\ndtoverlay=spi1-3cs\n# END PITOWER GEN2\n'
# Commit the whole file at once, retaining its permissions.
fd, temporary = tempfile.mkstemp(prefix='.pitower-', dir=p.parent)
try:
    with os.fdopen(fd, 'w') as output:
        output.write(s)
        output.flush()
        os.fsync(output.fileno())
    shutil.copymode(p, temporary)
    os.replace(temporary, p)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
printf 'i2c-dev\n' > /etc/modules-load.d/pitower-gen2.conf
modprobe i2c-dev || true
systemctl daemon-reload
systemctl enable "${units[@]}"
echo "Installation complete. Backup: $backup"
echo 'Reboot manually: sudo reboot'
echo "After reboot: sudo bash $0 status"
echo 'LCD shows system statistics, not the Kali desktop.'
echo 'Button requests Linux poweroff. Automatic board power-cut is not installed.'
