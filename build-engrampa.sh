#!/usr/bin/env bash
set -Eeuo pipefail

# Save generated packages in the directory where the command was launched.
OUTPUT_DIR="$(pwd -P)"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

command -v docker >/dev/null 2>&1 || fail 'Docker CLI was not found.'
docker info >/dev/null 2>&1 || fail 'Docker daemon is unavailable or this user cannot access it.'
[[ -w "$OUTPUT_DIR" ]] || fail 'The output directory is not writable.'
[[ -f "$SCRIPT_DIR/build-in-container.sh" ]] || fail "Missing build-in-container.sh beside $0."

# Docker's -v syntax uses colons as separators, so reject ambiguous paths early.
[[ "$OUTPUT_DIR$SCRIPT_DIR" != *:* ]] || fail 'The output and script directory paths must not contain a colon.'

# Select a base image from the host distribution or an explicitly reported base codename.
[[ -r /etc/os-release ]] || fail '/etc/os-release is missing; cannot determine the host distribution.'
# shellcheck disable=SC1091
source /etc/os-release
ID_LIKE=" ${ID_LIKE:-} "

case "${ID:-}" in
    ubuntu | debian)
        BASE_IMAGE_FAMILY="$ID"
        BASE_CODENAME="${VERSION_CODENAME:-}"
        ;;
    *)
        if [[ "$ID_LIKE" == *' ubuntu '* && -n "${UBUNTU_CODENAME:-}" ]]; then
            BASE_IMAGE_FAMILY=ubuntu
            BASE_CODENAME="$UBUNTU_CODENAME"
        elif [[ "$ID_LIKE" == *' debian '* && -n "${DEBIAN_CODENAME:-}" ]]; then
            BASE_IMAGE_FAMILY=debian
            BASE_CODENAME="$DEBIAN_CODENAME"
        else
            fail "Unsupported distribution '${ID:-unknown}'. Use Ubuntu, Debian, or a derivative that explicitly reports UBUNTU_CODENAME/DEBIAN_CODENAME."
        fi
        ;;
esac

# Accept only simple lowercase codenames safe to use in Docker tags and package versions.
[[ "$BASE_CODENAME" =~ ^[a-z0-9]+$ ]] || fail 'Could not determine a valid lowercase base codename from /etc/os-release.'
BASE_IMAGE="${BASE_IMAGE_FAMILY}:${BASE_CODENAME}"

# Leave nothing behind: remove the base image afterwards unless it was already on the host.
IMAGE_WAS_PRESENT=1
docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 || IMAGE_WAS_PRESENT=0
cleanup() {
    if [[ "$IMAGE_WAS_PRESENT" == 0 ]]; then
        docker image rm "$BASE_IMAGE" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# Bash handles Ctrl+C only after a foreground command ends, so run the container in the background and stop it explicitly.
CONTAINER_NAME="engrampa-build-$$"
DOCKER_PID=""
stop_container() {
    docker kill "$CONTAINER_NAME" >/dev/null 2>&1 || true
    [[ -z "$DOCKER_PID" ]] || wait "$DOCKER_PID" 2>/dev/null || true
    exit 130
}
trap stop_container INT TERM

# Build inside a disposable container of the host's distribution; only the two finished packages reach the output directory.
printf 'Build environment: %s\nOutput directory: %s\n' "$BASE_IMAGE" "$OUTPUT_DIR"
docker run --rm --init --name "$CONTAINER_NAME" \
    --volume "$OUTPUT_DIR:/output" \
    --volume "$SCRIPT_DIR/build-in-container.sh:/build.sh:ro" \
    "$BASE_IMAGE" bash /build.sh &
DOCKER_PID=$!
wait "$DOCKER_PID"
