#!/usr/bin/env bash
# Builds vmapple-cli for arm64 or x86-64 Linux with the Swift runtime, libtatsu and
# libplist linked in, so the binary needs only glibc 2.35 or later and libcurl.
# CI runs it in swift:6.4.2-jammy; a matching host with Docker can too:
#
#   docker run --rm -v "$PWD":/src -w /src swift:6.4.2-jammy .github/build-linux.sh
#
# Writes dist/vmapple-cli-linux-<arch>.tar.gz and its SHA-256.
set -euo pipefail

PLIST_VERSION=2.8.1
PLIST_SHA256=2a1792e5820e1657c173735fde75baeebd6dd967d2ac47be1e3891ddc64ebefa
TATSU_VERSION=1.1.0
TATSU_SHA256=96c8abd97552a4a0c487c701aba9a65d590c338dd331058ffb38304290b696c7

root=$(pwd)
case "$(uname -m)" in
    aarch64) archive_arch=arm64 ;;
    x86_64) archive_arch=x86_64 ;;
    *) echo "unsupported host architecture: $(uname -m)" >&2; exit 1 ;;
esac
work=$(mktemp -d)
deps=$work/prefix
export PKG_CONFIG_PATH=$deps/lib/pkgconfig
export CFLAGS="-O2 -fPIC"

# MARK: - Packages

if [ "$(id -u)" = 0 ] && command -v apt-get > /dev/null; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        build-essential pkg-config libcurl4-openssl-dev curl bzip2 ca-certificates file > /dev/null
fi

# MARK: - libplist and libtatsu

fetch() {
    local name=$1 version=$2 sha256=$3
    local archive=$work/$name-$version.tar.bz2
    curl -fsSL --retry 10 --retry-delay 15 --retry-all-errors -o "$archive" \
        "https://github.com/libimobiledevice/$name/releases/download/$version/$name-$version.tar.bz2"
    echo "$sha256  $archive" | sha256sum -c -
    tar -xjf "$archive" -C "$work"
}

fetch libplist "$PLIST_VERSION" "$PLIST_SHA256"
(cd "$work/libplist-$PLIST_VERSION" &&
    ./configure -q --prefix="$deps" --enable-static --disable-shared --without-cython --without-tools --without-tests &&
    make -s -j"$(nproc)" install)

fetch libtatsu "$TATSU_VERSION" "$TATSU_SHA256"
(cd "$work/libtatsu-$TATSU_VERSION" &&
    ./configure -q --prefix="$deps" --enable-static --disable-shared &&
    make -s -j"$(nproc)" install)

# MARK: - vmapple-cli

link=(-Xlinker -lcurl)
swift test "${link[@]}"
swift build -c release --static-swift-stdlib "${link[@]}"

binary=$(swift build -c release --static-swift-stdlib "${link[@]}" --show-bin-path)/vmapple-cli
mkdir -p "$root/dist"
staging=$work/vmapple-cli-linux-$archive_arch
mkdir -p "$staging"
strip -o "$staging/vmapple-cli" "$binary"
cp "$root/README.md" "$root/LICENSE" "$staging/"
"$staging/vmapple-cli" --help > /dev/null
file "$staging/vmapple-cli"
ldd "$staging/vmapple-cli"

tar -czf "$root/dist/vmapple-cli-linux-$archive_arch.tar.gz" -C "$work" "vmapple-cli-linux-$archive_arch"
(cd "$root/dist" && sha256sum "vmapple-cli-linux-$archive_arch.tar.gz" > "vmapple-cli-linux-$archive_arch.tar.gz.sha256")
cat "$root/dist/vmapple-cli-linux-$archive_arch.tar.gz.sha256"
