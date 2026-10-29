#!/bin/bash
#
# Put the containers in the state homelab-stacks.conf asks for, then clean up.
#
#   1. OFF stacks are stopped (their containers stay, so their images and
#      networks are kept and they can be turned on without a download).
#   2. ON stacks are brought up with 'compose up -d'. No updates: only images
#      that are missing get downloaded. Stacks in neither list are left alone.
#   3. Docker cleanup: every image no container uses (old versions, the
#      :previous rollback images), unused networks, the build cache.
#      Volumes are never touched: they can hold app data.
#
# --restart stops the ON stacks first, so they come up fresh on whatever
# images were just downloaded (used by aa-all_in_one.sh). If interrupted
# after that, the ON list is still brought back up.
#
# Usage: sudo ./xz-script_cleanup.sh [--restart]
# Exit codes: 0 ok, 1 fatal, 2 finished with warnings.

set -Eeuo pipefail
shopt -s nullglob

# --- config ---
USER_NAME="adler"
USER_HOME="/home/$USER_NAME"
ROOT_DIR="$USER_HOME/homelab/containers"
LOG_DIR="$USER_HOME/homelab/backup/logs"
LOCK_FILE="/run/lock/homelab-container-cleanup.lock"
STACKS_FILE="$(dirname "$(readlink -f "$0")")/homelab-stacks.conf"
LOG_KEEP_DAYS=90          # delete logs older than this

STOP_TIMEOUT=120          # seconds per stack
UP_TIMEOUT=600            # seconds per stack
SETTLE_SECONDS=20         # wait before checking the ON stacks
# --------------

RESTART=0
case "${1:-}" in
	"") ;;
	--restart) RESTART=1 ;;
	*) echo "Usage: $0 [--restart]" >&2; exit 1 ;;
esac

WARNINGS=()
STACKS=()
STARTED=()
STOPPED=()
STOP_BEGAN=0
UP_DONE=0

ts()   { date '+%F %T'; }
log()  { echo "$(ts) [INFO]  $*"; }
warn() { echo "$(ts) [WARN]  $*" >&2; WARNINGS+=("$*"); }
die()  { echo "$(ts) [FATAL] $*" >&2; exit 1; }

# Run a command with its full output in the log file. On a terminal, its
# latest status is shown live next to the stack name, with a running timer.
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

# Stop a stack, including orphans and profile services compose leaves out
stop_stack() {
	local s="$1" left
	live stop "$s" compose "$s" "$STOP_TIMEOUT" stop \
		|| warn "compose stop failed or timed out for $s: $LAST_LINE"
	left="$(running_ids "$s" | tr '\n' ' ')"
	if [ -n "${left// /}" ]; then
		# shellcheck disable=SC2086
		timeout "$STOP_TIMEOUT" docker stop $left >>"$LOG_FILE" 2>&1 || true
	fi
	if [ -n "$(running_ids "$s")" ]; then
		warn "$s still has running containers"
		return 1
	fi
}

up_on_list() {
	if [ "$UP_DONE" -eq 1 ]; then return 0; fi
	UP_DONE=1
	trap '' INT TERM HUP   # never leave the homelab half up
	local s
	log "Turning on ${#ON_STACKS[@]} stack(s)"
	for s in "${ON_STACKS[@]}"; do
		[ -f "$ROOT_DIR/$s/docker-compose.yml" ] || continue
		if live start "$s" compose "$s" "$UP_TIMEOUT" up -d; then
			log "  on      $s"
			STARTED+=("$s")
		else
			warn "up failed for $s: $LAST_LINE"
		fi
	done
}

on_exit() {
	local rc=$?
	chown -h "$USER_NAME:" "$LOG_DIR" "$LOG_DIR"/*.log 2>/dev/null || true
	if [ "$STOP_BEGAN" -eq 1 ]; then up_on_list; fi
	log "Summary: ${#STARTED[@]} on, ${#STOPPED[@]} off"
	if [ ${#WARNINGS[@]} -gt 0 ]; then
		echo "$(ts) [INFO]  ${#WARNINGS[@]} warning(s):"
		printf '    - %s\n' "${WARNINGS[@]}"
	fi
	if [ "$rc" -ne 0 ]; then
		echo "$(ts) [FATAL] Container cleanup FAILED (exit $rc), safe to run again" >&2
		exit "$rc"
	fi
	if [ ${#WARNINGS[@]} -gt 0 ]; then
		log "Container cleanup finished WITH WARNINGS"
		exit 2
	fi
	log "Container cleanup OK"
}

# --- preflight ---
[ "$(id -u)" -eq 0 ] || { echo "This script must be run as root (use sudo)." >&2; exit 1; }

# Live status line, only when run from a terminal
LIVE=0
if [ -t 1 ] && exec 8>/dev/tty; then LIVE=1; fi

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/container-cleanup-$(date +%F_%H%M%S).log"
# The logger ignores Ctrl+C so the summary always reaches the log
exec > >(trap '' INT TERM HUP; exec tee -a "$LOG_FILE") 2>&1
ln -sfn "${LOG_FILE##*/}" "$LOG_DIR/container-cleanup-latest.log"
find "$LOG_DIR" -maxdepth 1 -type f -name 'container-cleanup-20*.log' -mtime +"$LOG_KEEP_DAYS" -delete

exec 9>"$LOCK_FILE"
flock -n 9 || die "another container cleanup is already running (lock: $LOCK_FILE)"

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

for cmd in docker timeout flock; do
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
mapfile -t STACKS < <(
	{
		find "$ROOT_DIR" -mindepth 2 -maxdepth 2 -type f -name docker-compose.yml -printf '%h\n' \
			| sed "s#^$ROOT_DIR/##"
		for s in "${ON_STACKS[@]}" "${OFF_STACKS[@]}"; do
			if [ -f "$ROOT_DIR/$s/docker-compose.yml" ]; then echo "$s"; fi
		done
	} | sort -u
)
for s in "${STACKS[@]}"; do
	if ! in_list "$s" "${ON_STACKS[@]}" "${OFF_STACKS[@]}"; then
		warn "$s is in neither list, left as is ($(running_ids "$s" | wc -l) running)"
	fi
done

# --- off ---
if [ "$RESTART" -eq 1 ]; then
	STOP_BEGAN=1
	log "Stopping the ON stacks first (--restart)"
	for s in "${ON_STACKS[@]}"; do
		[ -f "$ROOT_DIR/$s/docker-compose.yml" ] || continue
		if [ -z "$(running_ids "$s")" ]; then continue; fi
		if stop_stack "$s"; then log "  off     $s"; fi
	done
fi

log "Turning off ${#OFF_STACKS[@]} stack(s)"
for s in "${OFF_STACKS[@]}"; do
	[ -f "$ROOT_DIR/$s/docker-compose.yml" ] || continue
	if [ -z "$(running_ids "$s")" ]; then
		log "  off     $s (already)"
		STOPPED+=("$s")
	elif stop_stack "$s"; then
		log "  off     $s"
		STOPPED+=("$s")
	fi
done

# --- on ---
up_on_list
trap 'exit 130' INT
trap 'exit 143' TERM HUP

log "Waiting ${SETTLE_SECONDS}s before checking"
sleep "$SETTLE_SECONDS"
for s in "${STARTED[@]}"; do
	while read -r name state status; do
		if [ "$state" = "restarting" ] || [ "$state" = "created" ] || [[ $status == *"(unhealthy)"* ]] \
			|| { [ "$state" = "exited" ] && [[ $status != "Exited (0)"* ]]; }; then
			warn "$s: container $name is $state ($status)"
		fi
	done < <(docker ps -a --filter "label=com.docker.compose.project.working_dir=$ROOT_DIR/$s" \
		--format '{{.Names}} {{.State}} {{.Status}}')
done

# --- docker cleanup ---
log "Docker disk use before cleanup:"
docker system df | sed 's/^/    /'

log "Removing images no container uses (old versions, :previous)"
live prune images docker image prune -af || warn "image prune failed: $LAST_LINE"
log "  $LAST_LINE"
log "Removing unused networks"
live prune networks docker network prune -f || warn "network prune failed: $LAST_LINE"
log "Removing the build cache"
live prune cache docker builder prune -af || warn "build cache prune failed: $LAST_LINE"
log "  $LAST_LINE"

log "Docker disk use after cleanup:"
docker system df | sed 's/^/    /'
unused_volumes="$(docker volume ls -qf dangling=true | wc -l)"
if [ "$unused_volumes" -gt 0 ]; then
	log "$unused_volumes volume(s) are not used by any container. Not removed (they can hold app data):"
	log "  review them with: docker volume ls -f dangling=true"
fi
