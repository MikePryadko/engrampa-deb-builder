#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

# Everything is built in the disposable container; only the finished packages are copied to /output.
WORK_DIR="$(mktemp -d /tmp/engrampa-build.XXXXXX)"
DEBIAN_PACKAGING_VERSION=""
UPSTREAM_VERSION=""

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

on_error() {
    printf 'ERROR: the build failed at line %s.\n' "$1" >&2
    if [[ -n "$DEBIAN_PACKAGING_VERSION" ]]; then
        printf 'Debian packaging %s may not fit upstream Engrampa %s yet; see the output above.\n' \
            "$DEBIAN_PACKAGING_VERSION" "$UPSTREAM_VERSION" >&2
    fi
}
trap 'on_error $LINENO' ERR

fetch() {
    curl --fail --silent --show-error --location --proto-redir '=https' --retry 3 --retry-delay 2 --connect-timeout 15 \
        --header 'User-Agent: engrampa-local-deb-builder' "$@"
}

[[ -d /output && -w /output ]] || fail 'The output directory is not writable from the container.'
# shellcheck disable=SC1091
source /etc/os-release
BASE_CODENAME="${VERSION_CODENAME:-}"
[[ "$BASE_CODENAME" =~ ^[a-z0-9]+$ ]] || fail 'Could not determine the base codename inside the container.'
BUILD_ARCH="$(dpkg --print-architecture)"

# Enable Ubuntu's Universe component inside the container; MATE build dependencies are published there.
if [[ "${ID:-}" == ubuntu ]]; then
    if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
        sed -i '/^Components:/ { /universe/! s/$/ universe/; }' /etc/apt/sources.list.d/ubuntu.sources
    elif [[ -f /etc/apt/sources.list ]]; then
        sed -i '/^[[:space:]]*deb / { / universe\([[:space:]]\|$\)/! s/$/ universe/; }' /etc/apt/sources.list
    fi
fi

printf 'Installing build tools...\n'
apt-get update
apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    devscripts \
    dpkg-dev \
    equivs \
    fakeroot \
    jq \
    xz-utils

# Ask GitHub for the latest stable release; no upstream version is hard-coded.
RELEASE_JSON="$(fetch --header 'Accept: application/vnd.github+json' \
    'https://api.github.com/repos/mate-desktop/engrampa/releases/latest')" \
    || fail 'Could not query GitHub for the latest Engrampa release.'
TAG="$(jq -er '.tag_name' <<< "$RELEASE_JSON")"
UPSTREAM_VERSION="${TAG#v}"
[[ "$UPSTREAM_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Unsupported latest release tag: $TAG"

# Use the release's own source archive and GitHub's SHA-256 digest when available.
ASSET="$(jq -er --arg v "$UPSTREAM_VERSION" '
    first(.assets[]
        | select(.name | test("^engrampa[-_]" + ($v | gsub("\\."; "\\.")) + "\\.tar\\.(xz|gz)$"))
        | "\(.browser_download_url) \((.digest // "") | sub("^sha256:"; ""))")' <<< "$RELEASE_JSON")" \
    || fail "No source tarball found in the Engrampa $UPSTREAM_VERSION release."
read -r SOURCE_URL SOURCE_SHA256 <<< "$ASSET"

printf 'Upstream release: %s\n' "$UPSTREAM_VERSION"
SOURCE_ARCHIVE="$WORK_DIR/engrampa-source.tar"
fetch "$SOURCE_URL" --output "$SOURCE_ARCHIVE"
if [[ -n "$SOURCE_SHA256" ]]; then
    printf '%s  %s\n' "$SOURCE_SHA256" "$SOURCE_ARCHIVE" | sha256sum --check --status \
        || fail 'The downloaded source archive failed its SHA-256 check.'
fi

# Fetch the current Debian packaging recipe (the debian/ directory): package split, dependencies, build rules.
DEBIAN_PACKAGING_VERSION="$(fetch 'https://sources.debian.org/api/src/engrampa/' \
    | jq -er '[.versions[] | select(any(.suites[]; . == "sid")) | .version][0]')" \
    || fail 'Could not determine the current Debian packaging version.'
[[ "$DEBIAN_PACKAGING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9][A-Za-z0-9.+~]*$ ]] \
    || fail "Unrecognized Debian packaging version: $DEBIAN_PACKAGING_VERSION"
printf 'Debian packaging: %s\n' "$DEBIAN_PACKAGING_VERSION"
fetch "https://deb.debian.org/debian/pool/main/e/engrampa/engrampa_${DEBIAN_PACKAGING_VERSION}.debian.tar.xz" \
    --output "$WORK_DIR/debian.tar.xz"

SOURCE_DIR="$WORK_DIR/engrampa"
mkdir -p "$SOURCE_DIR"
tar -xf "$SOURCE_ARCHIVE" --no-same-owner --no-same-permissions --directory "$SOURCE_DIR" --strip-components=1
tar -xJf "$WORK_DIR/debian.tar.xz" --no-same-owner --no-same-permissions --directory "$SOURCE_DIR"

# Keep the package installable on older releases that still name the 7-Zip backend p7zip-full.
if ! apt-cache show 7zip >/dev/null 2>&1; then
    apt-cache show p7zip-full >/dev/null 2>&1 || fail 'Neither 7zip nor p7zip-full is available in the distribution repositories.'
    grep -Eq '^[[:space:]]+7zip,[[:space:]]*$' "$SOURCE_DIR/debian/control" \
        || fail 'Could not find the expected 7zip runtime dependency to adapt for this distribution.'
    sed -i -E 's/^([[:space:]]*)7zip,[[:space:]]*$/\1 7zip | p7zip-full,/' "$SOURCE_DIR/debian/control"
    printf 'Using p7zip-full as a compatible alternative to the 7zip package name.\n'
fi

# Version the packages as Debian would: keep Debian's own version if it already packages this release, otherwise start a new packaging at revision 1.
cd "$SOURCE_DIR"
if [[ "${DEBIAN_PACKAGING_VERSION%-*}" == "$UPSTREAM_VERSION" ]]; then
    PACKAGE_VERSION="$DEBIAN_PACKAGING_VERSION"
else
    PACKAGE_VERSION="${UPSTREAM_VERSION}-1"
    DEBFULLNAME='Engrampa builder' DEBEMAIL='builder@localhost' \
        dch --newversion "$PACKAGE_VERSION" --distribution "$BASE_CODENAME" --force-distribution \
        'New upstream release.'
fi

# Apply Debian's patch series now so incompatibilities fail before build dependencies are installed.
dpkg-source --before-build "$SOURCE_DIR" \
    || fail "Debian packaging $DEBIAN_PACKAGING_VERSION has patches that do not apply to upstream Engrampa $UPSTREAM_VERSION."

mk-build-deps --install --remove --tool 'apt-get -y --no-install-recommends' debian/control

printf 'Building binary packages for %s...\n' "$BUILD_ARCH"
dpkg-buildpackage --build=binary --no-sign

# Publish the two packages in one step, owned by whoever owns the output directory.
shopt -s nullglob
MAIN_DEBS=("$WORK_DIR"/engrampa_[0-9]*_*.deb)
COMMON_DEBS=("$WORK_DIR"/engrampa-common_[0-9]*_all.deb)
[[ "${#MAIN_DEBS[@]}" -eq 1 && "${#COMMON_DEBS[@]}" -eq 1 ]] \
    || fail 'The build did not produce exactly one engrampa and one engrampa-common package.'
install -m 0644 -t /output "${MAIN_DEBS[0]}" "${COMMON_DEBS[0]}"
chown --reference=/output "/output/$(basename "${MAIN_DEBS[0]}")" "/output/$(basename "${COMMON_DEBS[0]}")"

printf '\nBuild completed successfully. Install both packages together:\n  sudo apt install ./%s ./%s\n' \
    "$(basename "${MAIN_DEBS[0]}")" "$(basename "${COMMON_DEBS[0]}")"
