#!/bin/bash
#
# Update the ON list from homelab-stacks.conf.
#
#   - Every ON stack gets its images pulled and is brought up with 'up -d'.
#     OFF stacks and stacks in neither list are not touched, and keep their
#     images.
#   - Pull first, then 'up -d': compose only recreates containers whose image
#     actually changed, so stacks without updates see no downtime.
#   - A failed pull skips that stack instead of taking it down.
#   - pihole and nginx go last, so DNS keeps working for every other pull.
#   - Afterwards every updated stack is checked. The image it replaced is
#     kept as <image>:previous (one level), so a bad update can be undone:
#       docker tag <image>:previous <image>:<tag> && docker compose up -d
#
# --pull-only downloads the updates without recreating anything (used by
# aa-all_in_one.sh, which restarts the stacks itself afterwards).
#
# Usage: sudo ./zy-script_updater.sh [--pull-only]
# Exit codes: 0 ok, 1 fatal, 2 finished with warnings.

set -Eeuo pipefail
shopt -s nullglob

# --- config ---
USER_NAME="adler"
USER_HOME="/home/$USER_NAME"
ROOT_DIR="$USER_HOME/homelab/containers"
LOG_DIR="$USER_HOME/homelab/backup/logs"
LOCK_FILE="/run/lock/homelab-container-update.lock"
STACKS_FILE="$(dirname "$(readlink -f "$0")")/homelab-stacks.conf"
LOG_KEEP_DAYS=90          # delete logs older than this

PULL_TIMEOUT=900          # seconds per stack
UP_TIMEOUT=600            # seconds per stack
SETTLE_SECONDS=30         # wait before checking updated stacks

# Stack folder names (relative to $ROOT_DIR) that are never updated
EXCLUDE_STACKS=(
	"spaceadler.com"   # website: never taken down, update it by hand
)

# Updated last, in this order, so a broken update cannot block the others
LAST_STACKS=(
	"nginx"
	"pihole"
)
# --------------

PULL_ONLY=0
case "${1:-}" in
	"") ;;
	--pull-only) PULL_ONLY=1 ;;
	*) echo "Usage: $0 [--pull-only]" >&2; exit 1 ;;
esac

WARNINGS=()
UPDATED=()
UNCHANGED=0
SKIPPED=0
CURRENT=""

ts()   { date '+%F %T'; }
log()  { echo "$(ts) [INFO]  $*"; }
warn() { echo "$(ts) [WARN]  $*" >&2; WARNINGS+=("$*"); }
die()  { echo "$(ts) [FATAL] $*" >&2; exit 1; }

# Full command output goes to the log file only, indented under its step
detail() {
	if [ -n "${1:-}" ]; then sed 's/^/    | /' <<<"$1" >>"$LOG_FILE"; fi
}

# Run a command with its full output in the log file. On a terminal, its
# latest status is shown live next to the stack name (pulling a layer,
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

# compose <stack> <timeout> <args...>, with the stack's profiles enabled
compose() {
	local s="$1" limit="$2"
	shift 2
	COMPOSE_PROFILES="${STACK_PROFILES[$s]:-}" timeout "$limit" \
		docker compose -f "$ROOT_DIR/$s/docker-compose.yml" --progress plain "$@"
}

# "<name> <image id> <image ref>" for every container of a stack (stopped
# ones too, so a stack that is down still shows what it would run), sorted
running_images() {
	local id
	for id in $(docker ps -aq --filter "label=com.docker.compose.project.working_dir=$ROOT_DIR/$1"); do
		docker inspect -f '{{.Name}} {{.Image}} {{.Config.Image}}' "$id"
	done | sort
}

# Tag the images a stack just moved away from as <repo>:previous
keep_previous() {
	local before="$1" after="$2" name id ref repo
	while read -r name id ref; do
		grep -qF "$name $id " <<<"$after " && continue
		[[ $ref == *@* ]] && continue    # pinned by digest, nothing to tag
		repo="$ref"
		[[ ${ref##*/} == *:* ]] && repo="${ref%:*}"
		if docker tag "$id" "$repo:previous" 2>/dev/null; then
			log "    kept ${name#/} rollback as $repo:previous"
		fi
	done <<<"$before"
}

on_exit() {
	local rc=$?
	chown -h "$USER_NAME:" "$LOG_DIR" "$LOG_DIR"/*.log 2>/dev/null || true
	if [ "$rc" -ne 0 ] && [ -n "$CURRENT" ]; then
		warn "interrupted while updating $CURRENT, check it with: docker compose -f $ROOT_DIR/$CURRENT/docker-compose.yml ps -a"
	fi
	log "Summary: ${#UPDATED[@]} updated, $UNCHANGED unchanged, $SKIPPED skipped"
	if [ ${#UPDATED[@]} -gt 0 ]; then
		printf '    updated: %s\n' "${UPDATED[@]}"
	fi
	if [ ${#WARNINGS[@]} -gt 0 ]; then
		echo "$(ts) [INFO]  ${#WARNINGS[@]} warning(s):"
		printf '    - %s\n' "${WARNINGS[@]}"
	fi
	if [ "$rc" -ne 0 ]; then
		echo "$(ts) [FATAL] Container update FAILED (exit $rc)" >&2
		exit "$rc"
	fi
	if [ ${#WARNINGS[@]} -gt 0 ]; then
		log "Container update finished WITH WARNINGS"
		exit 2
	fi
	log "Container update OK"
}

# --- preflight ---
[ "$(id -u)" -eq 0 ] || { echo "This script must be run as root (use sudo)." >&2; exit 1; }

# Live status line, only when run from a terminal
LIVE=0
if [ -t 1 ] && exec 8>/dev/tty; then LIVE=1; fi

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/container-update-$(date +%F_%H%M%S).log"
# The logger ignores Ctrl+C so the summary always reaches the log
exec > >(trap '' INT TERM HUP; exec tee -a "$LOG_FILE") 2>&1
ln -sfn "${LOG_FILE##*/}" "$LOG_DIR/container-update-latest.log"
find "$LOG_DIR" -maxdepth 1 -type f -name 'container-update-20*.log' -mtime +"$LOG_KEEP_DAYS" -delete

exec 9>"$LOCK_FILE"
flock -n 9 || die "another container update is already running (lock: $LOCK_FILE)"

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
STACKS=()
for s in "${ON_STACKS[@]}"; do
	if [ -f "$ROOT_DIR/$s/docker-compose.yml" ]; then
		STACKS+=("$s")
	else
		warn "$s is on the ON list but has no docker-compose.yml"
	fi
done
while read -r f; do
	s="${f#"$ROOT_DIR"/}"
	s="${s%/docker-compose.yml}"
	if ! in_list "$s" "${ON_STACKS[@]}" "${OFF_STACKS[@]}"; then
		warn "$s is in neither list, not updated"
	fi
done < <(find "$ROOT_DIR" -mindepth 2 -maxdepth 2 -type f -name docker-compose.yml | sort)

ORDER=()
for s in "${STACKS[@]}"; do
	if ! in_list "$s" "${LAST_STACKS[@]}"; then ORDER+=("$s"); fi
done
for s in "${LAST_STACKS[@]}"; do
	if in_list "$s" "${STACKS[@]}"; then ORDER+=("$s"); fi
done

# --- update ---
if [ "$PULL_ONLY" -eq 1 ]; then
	log "Downloading updates for ${#ORDER[@]} stack(s) from the ON list (--pull-only)"
else
	log "Updating ${#ORDER[@]} stack(s) from the ON list"
fi
for s in "${ORDER[@]}"; do
	if in_list "$s" "${EXCLUDE_STACKS[@]}"; then
		log "  skip      $s (excluded)"
		SKIPPED=$((SKIPPED + 1))
		continue
	fi

	before="$(running_images "$s")"

	CURRENT="$s"
	if ! live pull "$s" compose "$s" "$PULL_TIMEOUT" pull --ignore-buildable; then
		warn "pull failed for $s, left as is: $LAST_LINE"
		SKIPPED=$((SKIPPED + 1))
		CURRENT=""
		continue
	fi
	if [ "$PULL_ONLY" -eq 1 ]; then
		log "  pulled    $s"
		UNCHANGED=$((UNCHANGED + 1))
		CURRENT=""
		continue
	fi

	# Recreates only the services whose image changed (and starts the stack
	# if it was down); leaves orphans alone
	# After a containerd upgrade an old container can fail with "AlreadyExists";
	# recreating it fixes that (its volumes and bind mounts are kept)
	if ! live start "$s" compose "$s" "$UP_TIMEOUT" up -d \
		&& ! { [[ $LAST_LINE == *AlreadyExists* ]] \
			&& live recreate "$s" compose "$s" "$UP_TIMEOUT" up -d --force-recreate; }; then
		warn "up failed for $s: $LAST_LINE"
		keep_previous "$before" "$(running_images "$s")"
		CURRENT=""
		continue
	fi
	CURRENT=""

	after="$(running_images "$s")"
	if [ -z "$before" ]; then
		log "  started   $s (new)"
		UNCHANGED=$((UNCHANGED + 1))
	elif [ "$before" = "$after" ]; then
		log "  current   $s"
		UNCHANGED=$((UNCHANGED + 1))
	else
		log "  updated   $s"
		keep_previous "$before" "$after"
		UPDATED+=("$s")
	fi
done

# --- verify ---
if [ ${#UPDATED[@]} -gt 0 ]; then
	log "Waiting ${SETTLE_SECONDS}s before checking updated stacks"
	sleep "$SETTLE_SECONDS"
	for s in "${UPDATED[@]}"; do
		while read -r name state status; do
			if [ "$state" = "restarting" ] || [[ $status == *"(unhealthy)"* ]] \
				|| { [ "$state" = "exited" ] && [[ $status != "Exited (0)"* ]]; }; then
				warn "$s: container $name is $state ($status)"
			fi
		done < <(docker ps -a --filter "label=com.docker.compose.project.working_dir=$ROOT_DIR/$s" \
			--format '{{.Names}} {{.State}} {{.Status}}')
	done
fi

# --- cleanup ---
# Only dangling images (an older :previous that was just superseded).
# Images of OFF stacks are kept so they can start without a download.
log "Removing replaced images"
docker image prune -f | tail -n 1
