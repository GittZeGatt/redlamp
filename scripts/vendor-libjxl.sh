#!/usr/bin/env bash
#
# Builds libjxl, JPEG XL's reference library, into a static XCFramework at
# vendor/build/libjxl.xcframework, for JPEG XL export (EDT-30): ImageIO reads JPEG XL but doesn't
# write it.
#
# libjxl and the libraries it builds with (highway, brotli and skcms, at the commits libjxl pins as
# its submodules) are pinned, with their URLs and SHA-256s, in config/vendored-libs.json. As
# vendor-libraw.sh does LibRaw, the script compiles their library sources with clang, without
# CMake: libjxl's from the lists in its lib/jxl_lists.cmake, with the flags its own build uses, and
# the headers that build generates written here. Highway is compiled for each slice's baseline
# SIMD target alone (HWY_COMPILE_ONLY_STATIC): NEON, which every Apple Silicon chip has.
#
# The script is idempotent: a stamp file records the pins and flags, and a matching stamp
# short-circuits the build. JOBS sets how many files compile at once.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/config/vendored-libs.json"
CACHE="$ROOT/vendor/cache"
BUILD="$ROOT/vendor/build"
OUTPUT="$BUILD/libjxl.xcframework"
STAMP="$OUTPUT/.redlamp-stamp"
# libjxl first: its archive leaves the submodule folders the others unpack into.
LIBS=(libjxl highway brotli skcms)

read_config() {
    /usr/bin/python3 -c "import json,sys; print(json.load(open('$CONFIG'))['$1']['$2'])"
}

VERSION="$(read_config libjxl version)"
DEFINES="-DNDEBUG -DHWY_COMPILE_ONLY_STATIC=1 -DJXL_INTERNAL_LIBRARY_BUILD -DJXL_THREADS_INTERNAL_LIBRARY_BUILD"
DEFINES+=" -DJXL_STATIC_DEFINE -DJXL_CMS_STATIC_DEFINE -DJXL_THREADS_STATIC_DEFINE -DJPEGXL_ENABLE_SKCMS=1"
DEFINES+=" -DJPEGXL_ENABLE_TRANSCODE_JPEG=1 -DJPEGXL_ENABLE_BOXES=1 -DSKCMS_DISABLE_HSW -DSKCMS_DISABLE_SKX"
# Hidden, so the module that links it in exports none of it and dead-stripping drops what Redlamp
# doesn't call. The rest are libjxl's own: no exceptions or RTTI, maths that sets errno, and no
# auto-vectorizing, since Highway vectorizes it.
COMMON="-O2 -w -fPIC -fvisibility=hidden -funwind-tables"
CXXFLAGS="-std=c++17 $COMMON -fvisibility-inlines-hidden -fno-exceptions -fno-rtti -fmath-errno"
CXXFLAGS+=" -fmerge-all-constants -fno-builtin-fwrite -fno-builtin-fread -fsized-deallocation -fnew-alignment=8"
CXXFLAGS+=" -fno-vectorize -fno-slp-vectorize"
CFLAGS="-std=c11 $COMMON"

PINS=""
for lib in "${LIBS[@]}"; do
    PINS+="$lib $(read_config "$lib" version) $(read_config "$lib" sha256) "
done
STAMP_VALUE="$PINS$DEFINES $CXXFLAGS $CFLAGS"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$STAMP_VALUE" && "${FORCE:-0}" != "1" ]]; then
    echo "==> libjxl $VERSION already built ($OUTPUT)"
    exit 0
fi

mkdir -p "$CACHE" "$BUILD"
SRC="$CACHE/libjxl-$VERSION"
for lib in "${LIBS[@]}"; do
    version="$(read_config "$lib" version)"
    tarball="$CACHE/$lib-$version.tar.gz"
    if [[ ! -f "$tarball" ]]; then
        echo "==> Downloading $lib $version"
        curl -sfL -o "$tarball" "$(read_config "$lib" url)"
    fi
    expected="$(read_config "$lib" sha256)"
    actual="$(shasum -a 256 "$tarball" | cut -d' ' -f1)"
    if [[ "$actual" != "$expected" ]]; then
        echo "error: $lib tarball SHA mismatch (expected $expected, got $actual)" >&2
        exit 1
    fi
    dir="$SRC"
    [[ "$lib" == libjxl ]] || dir="$SRC/third_party/$lib"
    rm -rf "$dir"
    mkdir -p "$dir"
    tar -xzf "$tarball" -C "$dir" --strip-components=1
done

# The entries of a CMake list: `set(NAME` or `list(APPEND NAME`, one per line, up to `)`.
cmake_list() {
    awk -v start="$2" '$0 == start {flag=1; next} flag && /\)/ {exit} flag {print $1}' "$1"
}

SOURCES=()
add_sources() {
    local file="$1" start="$2" prefix="$3" count=0 entry
    while IFS= read -r entry; do
        if [[ "$entry" == *.cc ]]; then
            SOURCES+=("$prefix$entry")
            count=$((count + 1))
        fi
    done < <(cmake_list "$file" "$start")
    if [[ "$count" == 0 ]]; then
        echo "error: no sources in '$start' of ${file#"$SRC/"}" >&2
        exit 1
    fi
}
# libjxl's library as its CMake build makes it, with boxes and JPEG reconstruction on: the
# decoder, the encoder, the colour management and the thread pool.
for list in DEC DEC_BOX DEC_JPEG ENC CMS THREADS; do
    add_sources "$SRC/lib/jxl_lists.cmake" "set(JPEGXL_INTERNAL_${list}_SOURCES" "lib/"
done
add_sources "$SRC/third_party/highway/CMakeLists.txt" "  list(APPEND HWY_SOURCES" "third_party/highway/"
for part in common dec enc; do
    for file in "$SRC/third_party/brotli/c/$part"/*.c; do
        SOURCES+=("${file#"$SRC/"}")
    done
done
SOURCES+=(third_party/skcms/skcms.cc third_party/skcms/src/skcms_TransformBaseline.cc)
echo "==> Compiling ${#SOURCES[@]} libjxl, highway, brotli and skcms sources per slice"

# The headers libjxl's CMake build generates, written for a static library.
GENERATED="$BUILD/libjxl-generated"
rm -rf "$GENERATED"
mkdir -p "$GENERATED/jxl"
major="$(sed -nE 's/^set\(JPEGXL_MAJOR_VERSION ([0-9]+)\)/\1/p' "$SRC/lib/CMakeLists.txt")"
minor="$(sed -nE 's/^set\(JPEGXL_MINOR_VERSION ([0-9]+)\)/\1/p' "$SRC/lib/CMakeLists.txt")"
patch="$(sed -nE 's/^set\(JPEGXL_PATCH_VERSION ([0-9]+)\)/\1/p' "$SRC/lib/CMakeLists.txt")"
if [[ "$major.$minor.$patch" != "$VERSION" ]]; then
    echo "error: libjxl's CMakeLists.txt says $major.$minor.$patch, the pin $VERSION" >&2
    exit 1
fi
sed -e "s/@JPEGXL_MAJOR_VERSION@/$major/" -e "s/@JPEGXL_MINOR_VERSION@/$minor/" \
    -e "s/@JPEGXL_PATCH_VERSION@/$patch/" "$SRC/lib/jxl/version.h.in" > "$GENERATED/jxl/version.h"
for base in JXL JXL_CMS JXL_THREADS; do
    name="$(tr '[:upper:]' '[:lower:]' <<<"$base")"
    cat > "$GENERATED/jxl/${name}_export.h" <<EOF
#ifndef ${base}_EXPORT_H
#define ${base}_EXPORT_H
#define ${base}_EXPORT
#define ${base}_NO_EXPORT
#define ${base}_DEPRECATED __attribute__((__deprecated__))
#define ${base}_DEPRECATED_EXPORT ${base}_EXPORT ${base}_DEPRECATED
#define ${base}_DEPRECATED_NO_EXPORT ${base}_NO_EXPORT ${base}_DEPRECATED
#endif
EOF
done

HEADERS="$BUILD/libjxl-headers"
rm -rf "$HEADERS"
mkdir -p "$HEADERS/jxl" "$HEADERS/LibJXL"
cp "$SRC"/lib/include/jxl/*.h "$GENERATED"/jxl/*.h "$HEADERS/jxl/"
cat > "$HEADERS/LibJXL/redlamp_libjxl.h" <<'EOF'
#ifndef REDLAMP_LIBJXL_H
#define REDLAMP_LIBJXL_H
#include <jxl/decode.h>
#include <jxl/encode.h>
#include <jxl/thread_parallel_runner.h>
#endif
EOF
cat > "$HEADERS/LibJXL/module.modulemap" <<'EOF'
module LibJXL {
    header "redlamp_libjxl.h"
    link "c++"
    export *
}
EOF

INCLUDES="-I$GENERATED -I$SRC -I$SRC/lib/include -I$SRC/third_party/highway"
INCLUDES+=" -I$SRC/third_party/brotli/c/include -I$SRC/third_party/skcms"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
SLICES=(
    "macosx arm64-apple-macos26.0"
    "iphoneos arm64-apple-ios26.0"
    "iphonesimulator arm64-apple-ios26.0-simulator"
)

XCF_ARGS=()
for slice in "${SLICES[@]}"; do
    read -r sdk target <<<"$slice"
    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    objdir="$BUILD/libjxl-obj/$sdk"
    rm -rf "$objdir"
    mkdir -p "$objdir"
    echo "==> Building slice $sdk ($target)"
    # Objects are named by their paths: brotli's decoder and encoder each have a static_init.c.
    printf '%s\n' "${SOURCES[@]}" | xargs -P "$JOBS" -I{} sh -c '
        rel="$1"; out="$3/$(echo "$rel" | tr / _).o"
        # shellcheck disable=SC2086
        case "$rel" in
            *.c) xcrun clang -c "$2/$rel" -o "$out" -target "$4" -isysroot "$5" $6 $7 $9 ;;
            *) xcrun clang++ -c "$2/$rel" -o "$out" -target "$4" -isysroot "$5" $6 $8 $9 ;;
        esac
    ' _ {} "$SRC" "$objdir" "$target" "$sysroot" "$INCLUDES" "$CFLAGS" "$CXXFLAGS" "$DEFINES"
    xcrun libtool -static -o "$objdir/libjxl.a" "$objdir"/*.o 2>/dev/null
    XCF_ARGS+=(-library "$objdir/libjxl.a" -headers "$HEADERS")
done

rm -rf "$OUTPUT"
xcodebuild -create-xcframework "${XCF_ARGS[@]}" -output "$OUTPUT" >/dev/null
echo "$STAMP_VALUE" > "$STAMP"
# The XCFramework holds the libraries and headers. CI caches vendor/build with LibRaw's key too.
rm -rf "$BUILD/libjxl-obj" "$GENERATED" "$HEADERS"
echo "==> Built $OUTPUT"
