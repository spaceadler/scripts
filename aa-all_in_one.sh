#!/bin/bash
#
# Full maintenance run, one script after the other:
#
#   1. zy-script_updater.sh --pull-only   download container updates for the
#                                         ON list (first, while DNS is up)
#   2. xz-script_cleanup.sh --restart     stop the ON and OFF stacks, bring
#                                         the ON list up on the new images,
#                                         prune Docker
#   3. zx-system_updater.sh               update the OS
#   4. yy-system_cleanup.sh               clean the OS up
#
# Each step writes its own log; this one records the steps and their result.
# A failed step is reported and the run goes on, except that the OS cleanup
# is skipped when the OS update failed. Ctrl+C stops after the current step;
# step 2 always finishes bringing the ON list back.
#
# Usage: sudo ./aa-all_in_one.sh [-y]    (-y: no questions, for cron)
# Exit codes: 0 ok, 1 a step failed, 2 finished with warnings.

set -Eeuo pipefail

# --- config ---
USER_NAME="adler"
LOG_DIR="/home/$USER_NAME/homelab/backup/logs"
LOCK_FILE="/run/lock/homelab-all-in-one.lock"
LOG_KEEP_DAYS=90          # delete logs older than this
SCRIPTS="$(dirname "$(readlink -f "$0")")"
# --------------

YES=()
case "${1:-}" in
	"") ;;
	-y) YES=(-y) ;;
	*) echo "Usage: $0 [-y]" >&2; exit 1 ;;
esac

RESULTS=()
FAILED=0
WARNED=0
STOP_REQUESTED=0

ts()   { date '+%F %T'; }
log()  { echo "$(ts) [INFO]  $*"; }
die()  { echo "$(ts) [FATAL] $*" >&2; exit 1; }

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

on_exit() {
	local rc=$?
	chown -h "$USER_NAME:" "$LOG_DIR" "$LOG_DIR"/*.log 2>/dev/null || true
	log "Steps:"
	if [ ${#RESULTS[@]} -gt 0 ]; then printf '    %s\n' "${RESULTS[@]}"; fi
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

for s in zy-script_updater.sh xz-script_cleanup.sh zx-system_updater.sh yy-system_cleanup.sh; do
	[ -x "$SCRIPTS/$s" ] || die "missing or not executable: $SCRIPTS/$s"
done
log "Log file: $LOG_FILE"

# --- run ---
step "container updates (download)" zy-script_updater.sh --pull-only || true
step "containers: restart ON list, prune Docker" xz-script_cleanup.sh --restart || true
if step "system update" zx-system_updater.sh "${YES[@]}"; then
	step "system cleanup" yy-system_cleanup.sh "${YES[@]}" || true
else
	if [ "$STOP_REQUESTED" -eq 0 ]; then RESULTS+=("skipped  system cleanup (system update failed)"); fi
fi
