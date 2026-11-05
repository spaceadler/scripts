#!/bin/bash
#
# Full maintenance run. Every container is stopped once and started once:
#
#   1. zz-script_backup.sh --keep-down   stop everything, back it up as one
#                                        compressed file, leave it stopped
#   2. pihole only                       this machine's DNS, needed to download
#   3. zx-system_updater.sh              update the OS (a Docker upgrade can't
#                                        kill running apps: they're stopped)
#   4. yy-system_cleanup.sh              clean the OS up
#   5. zy-script_updater.sh              pull the ON list's updates and start
#                                        it, every container once
#   6. xz-script_cleanup.sh              OFF list off, prune Docker (with
#                                        --volumes: unused volumes too, see
#                                        xz-script_cleanup.sh)
#
# Then it shows what the backup costs on disk and how much was cleared.
#
# Each step writes its own log; this one records the steps and their result.
# If the backup fails nothing else runs (no copy to go back to) and the ON
# list is started as it was. The OS cleanup is skipped when the OS update
# failed. Ctrl+C stops after the current step, and whatever happens the ON
# list is started before this script exits.
#
# Run it inside tmux: if the terminal closes halfway, the OS update dies with
# it and can leave packages half-installed.
#
# Usage: sudo ./aa-all_in_one.sh [-y] [--volumes]
#   -y         no questions, for cron
#   --volumes  also delete unused volumes no compose file declares any more
# Exit codes: 0 ok, 1 a step failed, 2 finished with warnings.

set -Eeuo pipefail

# --- config ---
USER_NAME="adler"
ROOT_DIR="/home/$USER_NAME/homelab/containers"
LOG_DIR="/home/$USER_NAME/homelab/backup/logs"
LOCK_FILE="/run/lock/homelab-all-in-one.lock"
BACKUP_BASE="/home/$USER_NAME/homelab/backup/containers"
LOG_KEEP_DAYS=90          # delete logs older than this
DNS_STACK="pihole"        # started on its own right after the backup
SCRIPTS="$(dirname "$(readlink -f "$0")")"
# --------------

YES=()
XZ_ARGS=()
for arg in "$@"; do
	case "$arg" in
		-y) YES=(-y) ;;
		--volumes) XZ_ARGS=(--volumes) ;;
		*) echo "Usage: $0 [-y] [--volumes]" >&2; exit 1 ;;
	esac
done

RESULTS=()
REPORT=()
FAILED=0
WARNED=0
STOP_REQUESTED=0
STACKS_DOWN=0              # 1 from the backup until the ON list is started

ts()   { date '+%F %T'; }
log()  { echo "$(ts) [INFO]  $*"; }
die()  { echo "$(ts) [FATAL] $*" >&2; exit 1; }

# Used space in KB, summed over the filesystems the system, Docker and the
# backups live on (each counted once)
used_kb() {
	df -Pk / /var/lib/docker "$BACKUP_BASE" 2>/dev/null | awk 'NR > 1 && !seen[$1]++ {sum += $3} END {print sum + 0}'
}

# KB as "1.23 GB"
human() {
	awk -v kb="$1" 'BEGIN {
		sign = kb < 0 ? "-" : ""; kb = kb < 0 ? -kb : kb
		if (kb >= 1048576) printf "%s%.2f GB", sign, kb / 1048576
		else printf "%s%.0f MB", sign, kb / 1024
	}'
}

newest_backup() {
	find "$BACKUP_BASE" -mindepth 1 -maxdepth 1 -type f -name '20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]*.tar.zst' -printf '%f\n' 2>/dev/null | sort | tail -n 1
}

# step <name> <script> [args...]: run it on the terminal, record the result
step() {
	local name="$1" script="$2" rc
	shift 2
	if [ "$STOP_REQUESTED" -eq 1 ]; then
		RESULTS+=("skipped  $name (interrupted)")
		return 1
	fi
	log "=== $name"
	set +e
	if [ "$LIVE" -eq 1 ]; then
		# Straight to the terminal, so its live status line works
		"$SCRIPTS/$script" "$@" >&8 2>&8 <&0
	else
		"$SCRIPTS/$script" "$@"
	fi
	rc=$?
	set -e
	case "$rc" in
		0) RESULTS+=("ok       $name") ;;
		2) RESULTS+=("warnings $name (see its log)"); WARNED=1 ;;
		*) RESULTS+=("FAILED   $name (exit $rc, see its log)"); FAILED=1 ;;
	esac
	log "=== $name: exit $rc"
	[ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]
}

# Start pihole on its own (no update), so the OS and image downloads resolve
dns_up() {
	log "Starting $DNS_STACK (DNS)"
	if ! docker compose -f "$ROOT_DIR/$DNS_STACK/docker-compose.yml" up -d >>"$LOG_FILE" 2>&1; then
		RESULTS+=("FAILED   starting $DNS_STACK, downloads may fail")
		FAILED=1
	fi
}

on_exit() {
	local rc=$?
	chown -h "$USER_NAME:" "$LOG_DIR" "$LOG_DIR"/*.log 2>/dev/null || true
	# Never leave the homelab down: whatever stopped this run, start the ON list
	if [ "$STACKS_DOWN" -eq 1 ]; then
		trap '' INT TERM HUP
		log "Starting the ON list before exiting"
		STOP_REQUESTED=0
		step "start the ON list (safety)" xz-script_cleanup.sh || true
	fi
	log "Steps:"
	if [ ${#RESULTS[@]} -gt 0 ]; then printf '    %s\n' "${RESULTS[@]}"; fi
	if [ ${#REPORT[@]} -gt 0 ]; then
		log "Disk:"
		printf '    %s\n' "${REPORT[@]}"
	fi
	log "Logs: $LOG_DIR (each step has a *-latest.log)"
	if [ "$rc" -ne 0 ] || [ "$FAILED" -eq 1 ]; then
		echo "$(ts) [FATAL] All-in-one finished with FAILED steps" >&2
		exit 1
	fi
	if [ "$WARNED" -eq 1 ]; then
		log "All-in-one finished WITH WARNINGS"
		exit 2
	fi
	log "All-in-one OK"
}

# --- preflight ---
[ "$(id -u)" -eq 0 ] || { echo "This script must be run as root (use sudo)." >&2; exit 1; }

LIVE=0
if [ -t 1 ] && exec 8>/dev/tty; then LIVE=1; fi

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/all-in-one-$(date +%F_%H%M%S).log"
exec > >(trap '' INT TERM HUP; exec tee -a "$LOG_FILE") 2>&1
ln -sfn "${LOG_FILE##*/}" "$LOG_DIR/all-in-one-latest.log"
find "$LOG_DIR" -maxdepth 1 -type f -name 'all-in-one-20*.log' -mtime +"$LOG_KEEP_DAYS" -delete

exec 9>"$LOCK_FILE"
flock -n 9 || die "another all-in-one run is active (lock: $LOCK_FILE)"

trap on_exit EXIT
# The running step gets Ctrl+C itself and stops safely; this run then ends
# instead of starting the next step.
trap 'STOP_REQUESTED=1' INT TERM HUP

for s in zz-script_backup.sh zx-system_updater.sh yy-system_cleanup.sh zy-script_updater.sh xz-script_cleanup.sh; do
	[ -x "$SCRIPTS/$s" ] || die "missing or not executable: $SCRIPTS/$s"
done
[ -f "$ROOT_DIR/$DNS_STACK/docker-compose.yml" ] || die "no $DNS_STACK stack at $ROOT_DIR/$DNS_STACK"
if [ "$LIVE" -eq 1 ] && [ -z "${TMUX:-}${STY:-}" ]; then
	log "Tip: run this inside tmux, so closing the terminal can't interrupt the OS update"
fi
log "Log file: $LOG_FILE"

start_kb="$(used_kb)"

# --- 1. stop everything and back up ---
prev_backup="$(newest_backup)"
STACKS_DOWN=1
if ! step "stop and back up" zz-script_backup.sh --keep-down; then
	# zz already started the ON list again when it failed
	STACKS_DOWN=0
	if [ "$STOP_REQUESTED" -eq 0 ]; then
		RESULTS+=("skipped  everything else (no backup to fall back on)")
	fi
	exit 0
fi
backup="$(newest_backup)"
if [ -n "$backup" ] && [ "$backup" != "$prev_backup" ]; then
	REPORT+=("backup $backup: $(human "$(du -k "$BACKUP_BASE/$backup" | cut -f1)"), in $BACKUP_BASE")
fi

# --- 2. DNS ---
dns_up

# --- 3. and 4. system ---
system_freed_kb=0
if step "system update" zx-system_updater.sh "${YES[@]}"; then
	before_kb="$(used_kb)"
	step "system cleanup" yy-system_cleanup.sh "${YES[@]}" || true
	system_freed_kb=$(( before_kb - $(used_kb) ))
	if [ "$system_freed_kb" -lt 0 ]; then system_freed_kb=0; fi   # logs grew, nothing freed
else
	if [ "$STOP_REQUESTED" -eq 0 ]; then RESULTS+=("skipped  system cleanup (system update failed)"); fi
fi
# A Docker upgrade restarts the daemon, which can leave pihole stopped
dns_up

# --- 5. update and start the ON list ---
step "update and start the ON list" zy-script_updater.sh || true

# --- 6. OFF list off, prune Docker (also starts anything zy could not) ---
before_kb="$(used_kb)"
if step "container cleanup" xz-script_cleanup.sh "${XZ_ARGS[@]}"; then STACKS_DOWN=0; fi
docker_freed_kb=$(( before_kb - $(used_kb) ))
if [ "$docker_freed_kb" -lt 0 ]; then docker_freed_kb=0; fi

REPORT+=("cleared: $(human "$docker_freed_kb") by the container cleanup, $(human "$system_freed_kb") by the system cleanup, $(human $((docker_freed_kb + system_freed_kb))) in total")
REPORT+=("whole run: $(human $(( $(used_kb) - start_kb ))) more in use than before (backup and updates in, cleanups out), $(df -h --output=avail / | tail -n 1 | xargs) free")
