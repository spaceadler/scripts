#!/bin/bash
#
# Clean up the host OS (Debian / Raspberry Pi OS), best run after
# zx-system_updater.sh.
#
#   - Removes packages nothing needs any more (old kernels included), with
#     their config files.
#   - Purges the config files left behind by packages removed earlier
#     ("rc" in dpkg -l), which also deletes old kernels' leftover modules.
#   - Empties apt's download cache (the old .deb versions).
#   - Shrinks the systemd journal to the last $JOURNAL_KEEP.
#
# The running kernel is never removed. Shows what goes and asks first (skip
# with -y).
#
# Usage: sudo ./yy-system_cleanup.sh [-y]
# Exit codes: 0 ok, 1 failed, 2 finished with warnings.

set -Eeuo pipefail

# --- config ---
USER_NAME="adler"
LOG_DIR="/home/$USER_NAME/homelab/backup/logs"
LOCK_FILE="/run/lock/homelab-system-update.lock"   # same as the updater: never both at once
LOG_KEEP_DAYS=90          # delete logs older than this
APT_LOCK_TIMEOUT=600      # seconds to wait for another apt to finish
JOURNAL_KEEP="2weeks"     # journalctl --vacuum-time
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

on_exit() {
	local rc=$?
	chown -h "$USER_NAME:" "$LOG_DIR" "$LOG_DIR"/*.log 2>/dev/null || true
	if [ ${#WARNINGS[@]} -gt 0 ]; then
		echo "$(ts) [INFO]  ${#WARNINGS[@]} warning(s):"
		printf '    - %s\n' "${WARNINGS[@]}"
	fi
	if [ "$rc" -ne 0 ]; then
		echo "$(ts) [FATAL] System cleanup FAILED (exit $rc)" >&2
		exit "$rc"
	fi
	if [ ${#WARNINGS[@]} -gt 0 ]; then
		log "System cleanup finished WITH WARNINGS"
		exit 2
	fi
	log "System cleanup OK"
}

used_mb() { df -Pm / | awk 'NR==2 {print $3}'; }

APT=(apt-get -y -q
	-o "DPkg::Lock::Timeout=$APT_LOCK_TIMEOUT"
	-o Dpkg::Options::=--force-confdef
	-o Dpkg::Options::=--force-confold)
export DEBIAN_FRONTEND=noninteractive

# --- preflight ---
[ "$(id -u)" -eq 0 ] || { echo "This script must be run as root (use sudo)." >&2; exit 1; }

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/system-cleanup-$(date +%F_%H%M%S).log"
# The logger ignores Ctrl+C so the last lines always reach the log
exec > >(trap '' INT TERM HUP; exec tee -a "$LOG_FILE") 2>&1
ln -sfn "${LOG_FILE##*/}" "$LOG_DIR/system-cleanup-latest.log"
find "$LOG_DIR" -maxdepth 1 -type f -name 'system-cleanup-20*.log' -mtime +"$LOG_KEEP_DAYS" -delete

exec 9>"$LOCK_FILE"
flock -n 9 || die "a system update or cleanup is already running (lock: $LOCK_FILE)"

trap on_exit EXIT
log "Log file: $LOG_FILE"
before_mb="$(used_mb)"

# --- what would go ---
mapfile -t AUTOREMOVE < <(apt-get -s -o Debug::NoLocking=1 autoremove --purge | awk '/^Purg / {print $2}')
mapfile -t RESIDUAL < <(dpkg -l | awk '/^rc/ {print $2}')

running="$(uname -r)"
for p in "${AUTOREMOVE[@]}" "${RESIDUAL[@]}"; do
	if [[ $p == *"$running"* ]]; then die "refusing: $p belongs to the running kernel $running"; fi
done

if [ ${#AUTOREMOVE[@]} -gt 0 ]; then
	log "${#AUTOREMOVE[@]} package(s) no longer needed:"
	printf '    %s\n' "${AUTOREMOVE[@]}"
fi
if [ ${#RESIDUAL[@]} -gt 0 ]; then
	log "${#RESIDUAL[@]} removed package(s) with leftover config files:"
	printf '    %s\n' "${RESIDUAL[@]}"
fi
log "apt cache: $(du -sh /var/cache/apt 2>/dev/null | cut -f1), journal: $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | head -1)"

if [ ${#AUTOREMOVE[@]} -gt 0 ] || [ ${#RESIDUAL[@]} -gt 0 ]; then
	if [ "$ASSUME_YES" -eq 0 ]; then
		if [ -t 0 ]; then
			read -r -p "Remove these? [y/N] " answer
			[[ $answer =~ ^[Yy]$ ]] || { log "Aborted by user, nothing changed"; exit 0; }
		else
			die "not a terminal and -y not given, refusing to remove packages unattended"
		fi
	fi
fi

# --- clean ---
dpkg --configure -a

if [ ${#AUTOREMOVE[@]} -gt 0 ]; then
	log "Removing packages no longer needed"
	"${APT[@]}" autoremove --purge
fi

if [ ${#RESIDUAL[@]} -gt 0 ]; then
	log "Purging leftover config files"
	"${APT[@]}" purge "${RESIDUAL[@]}" || warn "some leftover configs could not be purged"
fi

log "Emptying the apt cache"
"${APT[@]}" clean

log "Trimming the journal to the last $JOURNAL_KEEP"
journalctl --vacuum-time="$JOURNAL_KEEP" 2>&1 | tail -n 1 || warn "journal vacuum failed"

after_mb="$(used_mb)"
log "Freed about $((before_mb - after_mb))M on / ($(df -h --output=avail / | tail -1 | xargs) free)"
