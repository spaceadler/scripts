#!/bin/bash
#
# Cold backup of every compose stack under $ROOT_DIR.
#
#   1. Stop everything that is running, so databases are flushed and the
#      copy is consistent.
#   2. rsync the whole tree into a dated snapshot (hardlinked against the
#      previous snapshot, so unchanged files cost no extra space).
#   3. Bring up the ON list from homelab-stacks.conf with 'compose up -d'.
#      No updates: only images that are missing get downloaded. OFF stacks
#      stay off, stacks in neither list go back to how they were.
#
# Step 3 is guaranteed by a trap: errors, Ctrl+C or SIGTERM at any point
# still bring the stacks back, and Ctrl+C is ignored while doing so.
#
# Usage: sudo ./zz-script_backup.sh
# Exit codes: 0 ok, 1 fatal (no snapshot), 2 snapshot made with warnings.

set -Eeuo pipefail
shopt -s nullglob

# --- config ---
USER_NAME="adler"
USER_HOME="/home/$USER_NAME"
ROOT_DIR="$USER_HOME/homelab/containers"
BACKUP_BASE="$USER_HOME/homelab/backup/containers"
LOG_DIR="$USER_HOME/homelab/backup/logs"
LOCK_FILE="/run/lock/homelab-backup.lock"
STACKS_FILE="$(dirname "$(readlink -f "$0")")/homelab-stacks.conf"
LOG_KEEP_DAYS=90          # delete logs older than this

KEEP_SNAPSHOTS=7          # completed snapshots to keep, 0 = never prune
STOP_TIMEOUT=120          # seconds per stack for a graceful stop
START_TIMEOUT=600         # seconds per stack to start
SETTLE_SECONDS=20         # wait before checking containers came back up

# Windows target (unused for now)
# WINDOWS_HOST="100.101.64.105"
# WINDOWS_USER="crackano"
# WINDOWS_PATH="D:/homelab/backup"
# --------------

WARNINGS=()
STACKS=()                  # every stack folder, relative to $ROOT_DIR
UNLISTED=()                # stacks in neither list
declare -A STACK_IDS=()    # stack -> container IDs that were running before
STOP_BEGAN=0
RESTORE_DONE=0
SNAPSHOT_DIR=""
PARTIAL_DIR=""

ts()   { date '+%F %T'; }
log()  { echo "$(ts) [INFO]  $*"; }
warn() { echo "$(ts) [WARN]  $*" >&2; WARNINGS+=("$*"); }
die()  { echo "$(ts) [FATAL] $*" >&2; exit 1; }

# Run a command with its full output in the log file. On a terminal, its
# latest status is shown live next to the stack name (stopping a container,
# waiting on a healthcheck, ...), with a running timer.
LAST_LINE=""
live() {
	local label="$1" stack="$2" start=$SECONDS cols rc
	shift 2
	cols="$(stty size </dev/tty 2>/dev/null | awk '{print $2}')" || true
	if ! [ "${cols:-0}" -ge 40 ] 2>/dev/null; then cols=100; fi
	echo "$(ts) [RUN]   $label $stack" >>"$LOG_FILE"
	set +e
	"$@" 2>&1 | {
		last="starting"
		while :; do
			IFS= read -r -t 1 line
			got=$?
			if [ "$got" -eq 0 ]; then
				printf '    | %s\n' "$line" >>"$LOG_FILE"
				line="${line#"${line%%[! ]*}"}"
				last="${line% }"
			elif [ "$got" -le 128 ]; then
				break
			fi
			if [ "$LIVE" -eq 1 ]; then
				status="$(printf '  %-7s %-20s %4ss  %s' "$label" "$stack" $((SECONDS - start)) "$last")"
				printf '\r\033[K%s' "${status:0:cols-1}" >&8
			fi
		done
	}
	rc=${PIPESTATUS[0]}
	set -e
	if [ "$LIVE" -eq 1 ]; then printf '\r\033[K' >&8; fi
	LAST_LINE="$(tail -n 1 "$LOG_FILE" | sed 's/^    | *//')"
	return "$rc"
}

in_list() {
	local needle="$1" item
	shift
	for item in "$@"; do
		if [ "$item" = "$needle" ]; then return 0; fi
	done
	return 1
}

# Running containers of a stack. Matching on the working_dir label also
# catches orphans and profile services compose would not touch by default.
running_ids() {
	docker ps -q --no-trunc \
		--filter "label=com.docker.compose.project.working_dir=$ROOT_DIR/$1" \
		--filter status=running
}

# compose <stack> <timeout> <args...>, with the stack's profiles enabled
compose() {
	local s="$1" limit="$2"
	shift 2
	COMPOSE_PROFILES="${STACK_PROFILES[$s]:-}" timeout "$limit" \
		docker compose -f "$ROOT_DIR/$s/docker-compose.yml" --progress plain "$@"
}

# Start containers that were running before and are not now (orphans, or
# services compose left out)
start_leftovers() {
	local s="$1" id
	for id in ${STACK_IDS[$s]:-}; do
		if [ "$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null)" != "true" ]; then
			docker start "$id" >>"$LOG_FILE" 2>&1 || true
		fi
	done
}

restore_stacks() {
	if [ "$RESTORE_DONE" -eq 1 ] || [ "$STOP_BEGAN" -eq 0 ]; then return 0; fi
	RESTORE_DONE=1
	trap '' INT TERM HUP   # never leave the homelab half up

	local s
	local -a started=()
	log "Starting the ON list (${#ON_STACKS[@]} stack(s))"
	for s in "${ON_STACKS[@]}"; do
		[ -f "$ROOT_DIR/$s/docker-compose.yml" ] || continue
		if live start "$s" compose "$s" "$START_TIMEOUT" up -d; then
			log "  on     $s"
		else
			warn "up failed for $s: $LAST_LINE"
		fi
		start_leftovers "$s"
		started+=("$s")
	done

	for s in "${UNLISTED[@]}"; do
		if [ -n "${STACK_IDS[$s]:-}" ]; then
			log "  back   $s (not in the lists, was running)"
			start_leftovers "$s"
			started+=("$s")
		fi
	done

	log "Waiting ${SETTLE_SECONDS}s before verifying"
	sleep "$SETTLE_SECONDS"
	local name state status
	for s in "${started[@]}"; do
		while read -r name state status; do
			if [ "$state" = "restarting" ] || [ "$state" = "created" ] || [[ $status == *"(unhealthy)"* ]] \
				|| { [ "$state" = "exited" ] && [[ $status != "Exited (0)"* ]]; }; then
				warn "$s: container $name is $state ($status)"
			fi
		done < <(docker ps -a --filter "label=com.docker.compose.project.working_dir=$ROOT_DIR/$s" \
			--format '{{.Names}} {{.State}} {{.Status}}')
	done
}

on_exit() {
	local rc=$?
	chown -h "$USER_NAME:" "$LOG_DIR" "$LOG_DIR"/*.log 2>/dev/null || true
	restore_stacks
	if [ -n "$PARTIAL_DIR" ] && [ -d "$PARTIAL_DIR" ]; then
		warn "incomplete snapshot left at $PARTIAL_DIR (will be reused next run)"
	fi
	if [ ${#WARNINGS[@]} -gt 0 ]; then
		echo "$(ts) [INFO]  ${#WARNINGS[@]} warning(s):"
		printf '    - %s\n' "${WARNINGS[@]}"
	fi
	if [ "$rc" -ne 0 ]; then
		echo "$(ts) [FATAL] Backup FAILED (exit $rc)" >&2
		exit "$rc"
	fi
	if [ ${#WARNINGS[@]} -gt 0 ]; then
		log "Backup finished WITH WARNINGS: $SNAPSHOT_DIR"
		exit 2
	fi
	log "Backup OK: $SNAPSHOT_DIR"
}

# --- preflight ---
[ "$(id -u)" -eq 0 ] || { echo "This script must be run as root (use sudo)." >&2; exit 1; }

# Live status line, only when run from a terminal
LIVE=0
if [ -t 1 ] && exec 8>/dev/tty; then LIVE=1; fi

mkdir -p "$BACKUP_BASE" "$LOG_DIR"
LOG_FILE="$LOG_DIR/backup-$(date +%F_%H%M%S).log"
# The logger ignores Ctrl+C, otherwise it would die and take the restore with it
exec > >(trap '' INT TERM HUP; exec tee -a "$LOG_FILE") 2>&1
ln -sfn "${LOG_FILE##*/}" "$LOG_DIR/backup-latest.log"
find "$LOG_DIR" -maxdepth 1 -type f -name 'backup-20*.log' -mtime +"$LOG_KEEP_DAYS" -delete

exec 9>"$LOCK_FILE"
flock -n 9 || die "another backup is already running (lock: $LOCK_FILE)"

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

for cmd in docker rsync timeout flock; do
	command -v "$cmd" >/dev/null || die "missing required command: $cmd"
done
docker info >/dev/null 2>&1 || die "docker daemon is not reachable"
[ -d "$ROOT_DIR" ] || die "source directory not found: $ROOT_DIR"
[ -f "$STACKS_FILE" ] || die "stack list not found: $STACKS_FILE"
# shellcheck source=homelab-stacks.conf
source "$STACKS_FILE"

log "Log file: $LOG_FILE"

# --- stacks ---
for s in "${ON_STACKS[@]}"; do
	if in_list "$s" "${OFF_STACKS[@]}"; then die "$s is in both ON_STACKS and OFF_STACKS"; fi
done
for s in "${ON_STACKS[@]}" "${OFF_STACKS[@]}"; do
	[ -f "$ROOT_DIR/$s/docker-compose.yml" ] || warn "$s is listed but has no docker-compose.yml"
done

# Everything at containers/<app>/, plus deeper stacks named in the lists
mapfile -t STACKS < <(
	{
		find "$ROOT_DIR" -mindepth 2 -maxdepth 2 -type f -name docker-compose.yml -printf '%h\n' \
			| sed "s#^$ROOT_DIR/##"
		for s in "${ON_STACKS[@]}" "${OFF_STACKS[@]}"; do
			if [ -f "$ROOT_DIR/$s/docker-compose.yml" ]; then echo "$s"; fi
		done
	} | sort -u
)
[ ${#STACKS[@]} -gt 0 ] || die "no docker-compose.yml files found under $ROOT_DIR"
for s in "${STACKS[@]}"; do
	if ! in_list "$s" "${ON_STACKS[@]}" "${OFF_STACKS[@]}"; then
		UNLISTED+=("$s")
		warn "$s is in neither list, it goes back to how it was"
	fi
done

# Folders that look like apps but use another file name are not stopped
for d in "$ROOT_DIR"/*/; do
	d="${d%/}"
	for f in compose.yml compose.yaml docker-compose.yaml; do
		if [ -f "$d/$f" ] && [ ! -f "$d/docker-compose.yml" ]; then
			warn "${d#"$ROOT_DIR"/}/$f is not named docker-compose.yml, it will be copied while running"
		fi
	done
done

# --- snapshot target ---
SNAPSHOT_DIR="$BACKUP_BASE/$(date +%F)"
if [ -e "$SNAPSHOT_DIR" ]; then SNAPSHOT_DIR="$BACKUP_BASE/$(date +%F_%H%M%S)"; fi
PARTIAL_DIR="$BACKUP_BASE/.partial"

# Newest completed snapshot, used as the hardlink base
LINK_DEST=""
mapfile -t EXISTING < <(find "$BACKUP_BASE" -mindepth 1 -maxdepth 1 -type d -name '20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]*' -printf '%f\n' | sort)
if [ ${#EXISTING[@]} -gt 0 ]; then LINK_DEST="$BACKUP_BASE/${EXISTING[-1]}"; fi

if [ -z "$LINK_DEST" ]; then
	need_kb="$(du -sk "$ROOT_DIR" | cut -f1)"
	avail_kb="$(df -Pk "$BACKUP_BASE" | awk 'NR==2 {print $4}')"
	[ "$avail_kb" -gt $((need_kb + need_kb / 10)) ] \
		|| die "not enough space: need ~$((need_kb / 1024))M, have $((avail_kb / 1024))M"
fi

# --- stop everything ---
# Record first, so a failure mid-stop still knows what to bring back
for s in "${STACKS[@]}"; do
	STACK_IDS[$s]="$(running_ids "$s" | tr '\n' ' ')"
done

STOP_BEGAN=1
log "Stopping all ${#STACKS[@]} stack(s)"
for s in "${STACKS[@]}"; do
	if [ -z "${STACK_IDS[$s]// /}" ]; then
		log "  off    $s (already)"
		continue
	fi
	live stop "$s" compose "$s" "$STOP_TIMEOUT" stop \
		|| warn "compose stop failed or timed out for $s: $LAST_LINE"

	# Orphans and profile services compose did not stop
	left="$(running_ids "$s" | tr '\n' ' ')"
	if [ -n "${left// /}" ]; then
		# shellcheck disable=SC2086
		timeout "$STOP_TIMEOUT" docker stop $left >>"$LOG_FILE" 2>&1 || true
	fi
	left="$(running_ids "$s" | tr '\n' ' ')"
	if [ -n "${left// /}" ]; then
		warn "$s still has running containers, its data is copied hot"
	else
		log "  off    $s"
	fi
done

# Running containers that no stack here owns are not part of a consistent copy
while read -r name wdir; do
	if [[ $wdir == "$ROOT_DIR"/* ]]; then
		warn "container $name (${wdir#"$ROOT_DIR"/}) is still running during the copy"
	fi
done < <(docker ps --format '{{.Names}} {{.Label "com.docker.compose.project.working_dir"}}')

# --- copy ---
log "Copying $ROOT_DIR -> $SNAPSHOT_DIR"
mkdir -p "$PARTIAL_DIR"
rsync_args=(-aHAX --numeric-ids --delete --info=stats1)
if [ -n "$LINK_DEST" ]; then
	rsync_args+=(--link-dest="$LINK_DEST")
	log "Hardlinking unchanged files against ${LINK_DEST##*/}"
fi

set +e
rsync "${rsync_args[@]}" "$ROOT_DIR/" "$PARTIAL_DIR/"
rsync_rc=$?
set -e
case "$rsync_rc" in
	0) ;;
	24) warn "some files vanished during the copy (rsync 24)" ;;
	*) die "rsync failed with exit code $rsync_rc" ;;
esac

mv "$PARTIAL_DIR" "$SNAPSHOT_DIR"
PARTIAL_DIR=""
log "Snapshot complete"

# --- bring the ON list back (also runs from the trap if anything failed) ---
restore_stacks

# --- retention ---
if [ "$KEEP_SNAPSHOTS" -gt 0 ]; then
	mapfile -t EXISTING < <(find "$BACKUP_BASE" -mindepth 1 -maxdepth 1 -type d -name '20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]*' -printf '%f\n' | sort)
	excess=$(( ${#EXISTING[@]} - KEEP_SNAPSHOTS ))
	for (( i = 0; i < excess; i++ )); do
		log "Pruning old snapshot ${EXISTING[$i]}"
		rm -rf --one-file-system -- "${BACKUP_BASE:?}/${EXISTING[$i]}"
	done
fi

log "Disk: $(df -h --output=used,avail,pcent "$BACKUP_BASE" | tail -1 | xargs)"
