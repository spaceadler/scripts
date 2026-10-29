#!/bin/bash
#
# Update the host OS (Debian / Raspberry Pi OS) safely.
#
#   - Shows what will change and asks first (skip with -y, e.g. from cron).
#   - Never stops on a config file prompt: local config files are kept.
#   - Waits for other apt/dpkg runs instead of failing on the lock.
#   - Repairs an interrupted dpkg run before starting.
#   - Tells you when a reboot is needed (new kernel or reboot-required).
#
# Usage: sudo ./zx-system_updater.sh [-y]
# Exit codes: 0 ok, 1 failed, 2 ok but reboot needed or warnings.

set -Eeuo pipefail

# --- config ---
USER_NAME="adler"
LOG_DIR="/home/$USER_NAME/homelab/backup/logs"
LOCK_FILE="/run/lock/homelab-system-update.lock"
LOG_KEEP_DAYS=90          # delete logs older than this
MIN_FREE_ROOT_MB=1024
MIN_FREE_BOOT_MB=100
APT_LOCK_TIMEOUT=600      # seconds to wait for another apt to finish
# --------------

ASSUME_YES=0
case "${1:-}" in
	"") ;;
	-y) ASSUME_YES=1 ;;
	*) echo "Usage: $0 [-y]" >&2; exit 1 ;;
esac

WARNINGS=()
ts()   { date '+%F %T'; }
log()  { echo "$(ts) [INFO]  $*"; }
warn() { echo "$(ts) [WARN]  $*" >&2; WARNINGS+=("$*"); }
die()  { echo "$(ts) [FATAL] $*" >&2; exit 1; }

# Full command output goes to the log file only, indented under its step
detail() {
	if [ -n "${1:-}" ]; then sed 's/^/    | /' <<<"$1" >>"$LOG_FILE"; fi
}

on_exit() {
	local rc=$?
	chown -h "$USER_NAME:" "$LOG_DIR" "$LOG_DIR"/*.log 2>/dev/null || true
	if [ ${#WARNINGS[@]} -gt 0 ]; then
		echo "$(ts) [INFO]  ${#WARNINGS[@]} warning(s):"
		printf '    - %s\n' "${WARNINGS[@]}"
	fi
	if [ "$rc" -ne 0 ]; then
		echo "$(ts) [FATAL] System update FAILED (exit $rc)" >&2
		exit "$rc"
	fi
	if [ ${#WARNINGS[@]} -gt 0 ]; then
		log "System update finished WITH WARNINGS"
		exit 2
	fi
	log "System update OK"
}

free_mb() { df -Pm "$1" | awk 'NR==2 {print $4}'; }

APT=(apt-get -y -q
	-o "DPkg::Lock::Timeout=$APT_LOCK_TIMEOUT"
	-o Dpkg::Options::=--force-confdef
	-o Dpkg::Options::=--force-confold)
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# --- preflight ---
[ "$(id -u)" -eq 0 ] || { echo "This script must be run as root (use sudo)." >&2; exit 1; }

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/system-update-$(date +%F_%H%M%S).log"
# The logger ignores Ctrl+C so the last lines always reach the log
exec > >(trap '' INT TERM HUP; exec tee -a "$LOG_FILE") 2>&1
ln -sfn "${LOG_FILE##*/}" "$LOG_DIR/system-update-latest.log"
find "$LOG_DIR" -maxdepth 1 -type f -name 'system-update-20*.log' -mtime +"$LOG_KEEP_DAYS" -delete

exec 9>"$LOCK_FILE"
flock -n 9 || die "another system update is already running (lock: $LOCK_FILE)"

trap on_exit EXIT
log "Log file: $LOG_FILE"

root_free="$(free_mb /)"
[ "$root_free" -ge "$MIN_FREE_ROOT_MB" ] || die "only ${root_free}M free on /, need ${MIN_FREE_ROOT_MB}M"
if mountpoint -q /boot/firmware; then
	boot_free="$(free_mb /boot/firmware)"
	[ "$boot_free" -ge "$MIN_FREE_BOOT_MB" ] || die "only ${boot_free}M free on /boot/firmware, need ${MIN_FREE_BOOT_MB}M"
fi

# --- repair an interrupted run ---
log "Checking for an interrupted dpkg run"
dpkg --configure -a
"${APT[@]}" --fix-broken install >>"$LOG_FILE" 2>&1

# --- refresh ---
log "Refreshing package lists"
"${APT[@]}" update

mapfile -t PENDING < <(apt-get -s -o Debug::NoLocking=1 full-upgrade | awk '/^Inst / {print $2}')
if [ ${#PENDING[@]} -eq 0 ]; then
	log "Already up to date"
else
	log "${#PENDING[@]} package(s) to upgrade:"
	printf '    %s\n' "${PENDING[@]}"

	if printf '%s\n' "${PENDING[@]}" | grep -qE '^(docker-ce|containerd\.io|docker-compose-plugin)$'; then
		warn "Docker is being upgraded, every container will restart"
	fi

	if [ "$ASSUME_YES" -eq 0 ]; then
		if [ -t 0 ]; then
			read -r -p "Proceed? [y/N] " answer
			[[ $answer =~ ^[Yy]$ ]] || { log "Aborted by user, nothing changed"; exit 0; }
		else
			die "not a terminal and -y not given, refusing to upgrade unattended"
		fi
	fi

	# full-upgrade is what Raspberry Pi OS expects (kernel and firmware packages
	# sometimes add or remove dependencies, which plain upgrade holds back)
	log "Upgrading"
	"${APT[@]}" full-upgrade
fi

log "Removing packages that are no longer needed"
"${APT[@]}" autoremove --purge
"${APT[@]}" clean

# --- reboot check ---
if [ -f /var/run/reboot-required ]; then
	warn "reboot required ($(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null || echo 'see /var/run/reboot-required'))"
fi
running="$(uname -r)"
flavor="${running##*-}"   # e.g. v8 or 2712
newest="$(find /lib/modules -mindepth 1 -maxdepth 1 -type d -name "*-$flavor" -printf '%f\n' | sort -V | tail -1)"
if [ -n "$newest" ] && [ "$newest" != "$running" ]; then
	warn "new kernel installed ($newest, running $running), reboot to use it"
fi
