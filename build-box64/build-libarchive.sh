#!/usr/bin/env bash
# ================================================================
# libtar.so build for HarmonyOS HAP integration
# ----------------------------------------------------------------
# 输出: out/libtar.so
# 导出: bsdtar_main(int argc, char** argv)
# 依赖: 全静态链接 (zlib + liblzma + libzstd + libarchive)
#
# HAP NAPI 调用契约:
#   1. fork()
#   2. dlopen("libtar.so", RTLD_NOW|RTLD_LOCAL)
#   3. dlsym(h, "bsdtar_main")
#   4. bsdtar_main(argc, argv)  →  正常返回 exit code
#
# 用法:
#   bash build_libtar.sh
#   bash build_libtar.sh --no-fetch     # 已有源码, 跳过下载
#   bash build_libtar.sh --no-reset     # 增量: 不清 build 目录, 不重跑 patch
#   bash build_libtar.sh --no-xz        # 关掉 .xz / .lzma 支持
#   bash build_libtar.sh --no-zstd      # 关掉 .zst 支持
# ================================================================
set -e
START=$(date +%s%N)

# ================================================================
# 0. 环境
# ================================================================
export OHOS_SDK="${OHOS_SDK:-/workspace/ohos-sdk/linux}"
export OHOS_TOOLCHAIN="$OHOS_SDK/native/build/cmake/ohos.toolchain.cmake"
export OHOS_CMAKE="$OHOS_SDK/native/build-tools/cmake/bin/cmake"
export OHOS_NINJA="$OHOS_SDK/native/build-tools/cmake/bin/ninja"
export OHOS_ARCH="${OHOS_ARCH:-arm64-v8a}"

ROOT=/workspace/dev/libarchive
THIRDPARTY=$ROOT/thirdparty
OUT=$ROOT/out

# 依赖版本 (pinned; 想升级自己改)
LIBARCHIVE_VER=3.7.7
ZLIB_VER=1.3.1
XZ_VER=5.4.1
ZSTD_VER=1.5.6

FETCH=1
RESET=1
ENABLE_XZ=1
ENABLE_ZSTD=1

for arg in "$@"; do
    case "$arg" in
        --no-fetch) FETCH=0 ;;
        --no-reset) RESET=0 ;;
        --no-xz)    ENABLE_XZ=0 ;;
        --no-zstd)  ENABLE_ZSTD=0 ;;
        *) echo "未知参数: $arg"; exit 1 ;;
    esac
done

for f in "$OHOS_TOOLCHAIN" "$OHOS_CMAKE" "$OHOS_NINJA"; do
    if [ ! -e "$f" ]; then echo "ERROR: 找不到 $f"; exit 1; fi
done

mkdir -p "$THIRDPARTY" "$OUT"

echo "==> environment"
echo "    OHOS_SDK    = $OHOS_SDK"
echo "    OHOS_ARCH   = $OHOS_ARCH"
echo "    thirdparty  = $THIRDPARTY"
echo "    out         = $OUT"
echo "    xz support  = $ENABLE_XZ"
echo "    zstd support= $ENABLE_ZSTD"

# ================================================================
# 1. 拉取源码 (tarball -> 解压)
# ================================================================
fetch_tarball() {
    local name="$1"
    local url="$2"
    local dir="$3"
    if [ -d "$dir" ]; then
        echo "==> $name 已存在: $dir"
        return
    fi
    local tarball="$THIRDPARTY/${name}.tar.gz"
    if [ ! -f "$tarball" ]; then
        echo "==> download $name from $url"
        curl -fL "$url" -o "$tarball"
    fi
    echo "==> extract $name"
    tar -xf "$tarball" -C "$THIRDPARTY"
}

if [ $FETCH -eq 1 ]; then
    rm -rf "$THIRDPARTY"
    mkdir -p "$THIRDPARTY"

    fetch_tarball "zlib-${ZLIB_VER}" \
        "https://zlib.net/fossils/zlib-${ZLIB_VER}.tar.gz" \
        "$THIRDPARTY/zlib-${ZLIB_VER}"

    fetch_tarball "libarchive-${LIBARCHIVE_VER}" \
        "https://github.com/libarchive/libarchive/releases/download/v${LIBARCHIVE_VER}/libarchive-${LIBARCHIVE_VER}.tar.gz" \
        "$THIRDPARTY/libarchive-${LIBARCHIVE_VER}"

    if [ $ENABLE_XZ -eq 1 ]; then
        fetch_tarball "xz-${XZ_VER}" \
            "https://github.com/tukaani-project/xz/releases/download/v${XZ_VER}/xz-${XZ_VER}.tar.gz" \
            "$THIRDPARTY/xz-${XZ_VER}"
    fi
    if [ $ENABLE_ZSTD -eq 1 ]; then
        fetch_tarball "zstd-${ZSTD_VER}" \
            "https://github.com/facebook/zstd/releases/download/v${ZSTD_VER}/zstd-${ZSTD_VER}.tar.gz" \
            "$THIRDPARTY/zstd-${ZSTD_VER}"
    fi
fi

ZLIB_SRC="$THIRDPARTY/zlib-${ZLIB_VER}"
ARCH_SRC="$THIRDPARTY/libarchive-${LIBARCHIVE_VER}"
XZ_SRC="$THIRDPARTY/xz-${XZ_VER}"
ZSTD_SRC="$THIRDPARTY/zstd-${ZSTD_VER}"

INSTALL_PREFIX="$THIRDPARTY/install"
if [ $RESET -eq 1 ]; then
    echo "==> reset $INSTALL_PREFIX"
    rm -rf "$INSTALL_PREFIX"
fi
mkdir -p "$INSTALL_PREFIX"

# ================================================================
# 2. Patch bsdtar
#    2.1 main() -> bsdtar_main() + visibility
#    2.2 ADD_EXECUTABLE(bsdtar) -> ADD_LIBRARY(bsdtar SHARED) 输出 libtar.so
#    2.3 禁用 INSTALL(bsdtar) 避免安装期报错
# ================================================================
apply_patches() {
    local mark="OHOS_LIBTAR_PATCH"
    local bsdtar_c="$ARCH_SRC/tar/bsdtar.c"
    local tar_cml="$ARCH_SRC/tar/CMakeLists.txt"

    if [ ! -f "$bsdtar_c" ]; then
        echo "ERROR: $bsdtar_c 不存在"; exit 1
    fi

    # ---- 2.1 bsdtar.c ----
    if grep -q "$mark" "$bsdtar_c"; then
        echo "==> patch bsdtar.c already"
    else
        echo "==> patch bsdtar.c: main -> bsdtar_main"
        python3 - "$bsdtar_c" "$mark" << 'PY'
import sys, re
p, mark = sys.argv[1], sys.argv[2]
s = open(p).read()

# 匹配典型 main 签名. bsdtar 3.6+ 用 (int argc, char **argv)
pat = re.compile(
    r'\bint\s+main\s*\(\s*int\s+\w+\s*,\s*char\s*\*\*\s*\w+\s*\)')
m = pat.search(s)
if not m:
    print("ERROR: main() signature not found in bsdtar.c", file=sys.stderr)
    sys.exit(1)

new_sig = '__attribute__((visibility("default"))) int bsdtar_main(int argc, char **argv)'
s = s[:m.start()] + new_sig + s[m.end():]

s = '/* ' + mark + ' */\n' + s
open(p, 'w').write(s)
print("  patched")
PY
    fi

    # ---- 2.2 + 2.3 tar/CMakeLists.txt ----
    if grep -q "$mark" "$tar_cml"; then
        echo "==> patch tar/CMakeLists.txt already"
    else
        echo "==> patch tar/CMakeLists.txt: exec -> shared, output=libtar.so"
        python3 - "$tar_cml" "$mark" << 'PY'
import sys, re
p, mark = sys.argv[1], sys.argv[2]
s = open(p).read()

# 1) ADD_EXECUTABLE(bsdtar ...)  ->  ADD_LIBRARY(bsdtar SHARED ...)
#    大小写不一, 用 IGNORECASE
n_replaced = 0
def repl_add(m):
    global n_replaced
    n_replaced += 1
    return 'ADD_LIBRARY(bsdtar SHARED'
s = re.sub(r'\bADD_EXECUTABLE\s*\(\s*bsdtar\b',
           repl_add, s, flags=re.IGNORECASE)
if n_replaced == 0:
    print("ERROR: ADD_EXECUTABLE(bsdtar ...) not found", file=sys.stderr)
    sys.exit(1)

# 2) 把 INSTALL(TARGETS bsdtar ...) 整个语句注释掉.
#    简单粗暴: 找到 INSTALL(TARGETS bsdtar 后括号平衡到 )
def comment_out_install(text):
    out = []
    i = 0
    while i < len(text):
        m = re.match(r'\s*INSTALL\s*\(\s*TARGETS\s+bsdtar\b',
                     text[i:], re.IGNORECASE)
        if not m:
            out.append(text[i])
            i += 1
            continue
        # 找配对 ')'
        j = i + m.end()
        # m.end() 到的是 'bsdtar' 之后, 找 '('...
        # 但 INSTALL( 已经被 m 覆盖, m.end() 停在 'bsdtar' 后.
        # 我们要从 INSTALL 起始位置往后找匹配括号.
        stmt_start = i + m.start()
        # 从 stmt_start 找第一个 '(', 然后括号平衡
        pi = text.find('(', stmt_start)
        depth = 0
        k = pi
        while k < len(text):
            if text[k] == '(':
                depth += 1
            elif text[k] == ')':
                depth -= 1
                if depth == 0:
                    break
            k += 1
        # 注释掉 [stmt_start, k+1]
        out.append(text[i:stmt_start])
        stmt = text[stmt_start:k+1]
        # 逐行加 '#'
        commented = '\n'.join('# ' + ln for ln in stmt.split('\n'))
        out.append('# OHOS_LIBTAR_PATCH: disabled INSTALL for shared build\n')
        out.append(commented)
        i = k + 1
    return ''.join(out)
s = comment_out_install(s)

# 3) 在 ADD_LIBRARY(bsdtar SHARED ...) 语句结束后追加输出名
def inject_props(text):
    m = re.search(r'\bADD_LIBRARY\s*\(\s*bsdtar\s+SHARED\b',
                  text, re.IGNORECASE)
    if not m:
        return text
    # 找配对 ')'
    pi = text.find('(', m.start())
    depth = 0
    k = pi
    while k < len(text):
        if text[k] == '(':
            depth += 1
        elif text[k] == ')':
            depth -= 1
            if depth == 0:
                break
        k += 1
    inject = '''

# OHOS_LIBTAR_PATCH: output libtar.so and clean symbol visibility
SET_TARGET_PROPERTIES(bsdtar PROPERTIES
    OUTPUT_NAME tar
    PREFIX     "lib"
    SUFFIX     ".so"
    C_VISIBILITY_PRESET hidden
    POSITION_INDEPENDENT_CODE ON
)
'''
    return text[:k+1] + inject + text[k+1:]
s = inject_props(s)

# 4) 顶部 mark
s = '# ' + mark + '\n' + s

open(p, 'w').write(s)
print("  patched")
PY
    fi
}

if [ $RESET -eq 1 ]; then
    apply_patches
else
    echo "==> --no-reset: 跳过 patch (依赖现有源码状态)"
fi

# ================================================================
# 3. 编译 zlib (静态)
# ================================================================
build_zlib() {
    echo "==> build zlib (static)"
    local B="$THIRDPARTY/build-zlib"
    [ $RESET -eq 1 ] && rm -rf "$B"
    mkdir -p "$B" && cd "$B"

    "$OHOS_CMAKE" "$ZLIB_SRC" -GNinja \
        -DCMAKE_MAKE_PROGRAM="$OHOS_NINJA" \
        -DCMAKE_TOOLCHAIN_FILE="$OHOS_TOOLCHAIN" \
        -DOHOS_ARCH="$OHOS_ARCH" \
        -DOHOS_PLATFORM=OHOS \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DZLIB_BUILD_EXAMPLES=OFF \
        > "$B/configure.log" 2>&1

    "$OHOS_NINJA" -j"$(nproc)"
    "$OHOS_NINJA" install
    # zlib 装完可能有 libz.so.* 也留着, 用 libz.a
}
build_zlib

# ================================================================
# 4. 编译 xz (autotools, 静态) — CMake 分支有 unxz symlink 冲突 bug,
#    xz 主推 autotools, 5.4.7 是最后一个 pre-backdoor 稳定版.
#    需要 5.6.x 只改 XZ_VER 即可, autotools 分支一直可用.
# ================================================================
build_xz() {
    echo "==> build xz (autotools, static)"
    local B="$THIRDPARTY/build-xz"
    [ $RESET -eq 1 ] && rm -rf "$B"
    mkdir -p "$B" && cd "$B"

    local LLVM_BIN="$OHOS_SDK/native/llvm/bin"
    local SYSROOT="$OHOS_SDK/native/sysroot"

    # ohos-clang wrapper 自己处理 target/sysroot, --host 只用来做
    # autotools 的 host_os/host_cpu 猜测. xz 5.4.1 的 config.sub 不认
    # 'ohos' 这个 OS token, 用通用 aarch64-linux 绕开. 参考:
    #   OpenHarmony community PKGBUILD (host="aarch64-linux")
    local CC_BIN=""
    if [ -x "$LLVM_BIN/aarch64-unknown-linux-ohos-clang" ]; then
        CC_BIN="$LLVM_BIN/aarch64-unknown-linux-ohos-clang"
    elif [ -x "$LLVM_BIN/clang" ]; then
        CC_BIN="$LLVM_BIN/clang --target=aarch64-linux-ohos --sysroot=$SYSROOT"
    else
        echo "ERROR: 找不到 clang 在 $LLVM_BIN"; exit 1
    fi
    local HOST_TRIPLE="aarch64-linux"       # <-- 关键: 不带 ohos
    local AR_BIN="$LLVM_BIN/llvm-ar"
    local RANLIB_BIN="$LLVM_BIN/llvm-ranlib"
    local STRIP_BIN="$LLVM_BIN/llvm-strip"

    local CFLAGS_XZ="-O3 -fPIC -fstack-protector-strong -DNDEBUG"
    local LDFLAGS_XZ="-Wl,-z,relro,-z,now -Wl,--disable-new-dtags"

    if [ -d "$SYSROOT" ] && ! echo "$CC_BIN" | grep -q sysroot; then
        CFLAGS_XZ="$CFLAGS_XZ --sysroot=$SYSROOT"
        LDFLAGS_XZ="$LDFLAGS_XZ --sysroot=$SYSROOT"
    fi

    if [ ! -x "$XZ_SRC/configure" ]; then
        echo "ERROR: $XZ_SRC/configure 不存在."
        exit 1
    fi

    echo "    CC       = $CC_BIN"
    echo "    HOST     = $HOST_TRIPLE  (autotools 用, 不含 ohos)"
    echo "    SYSROOT  = $SYSROOT"

    CC="$CC_BIN" \
    AR="$AR_BIN" \
    RANLIB="$RANLIB_BIN" \
    STRIP="$STRIP_BIN" \
    CFLAGS="$CFLAGS_XZ" \
    LDFLAGS="$LDFLAGS_XZ" \
    "$XZ_SRC/configure" \
        --host="$HOST_TRIPLE" \
        --prefix="$INSTALL_PREFIX" \
        --enable-static \
        --disable-shared \
        --disable-xz \
        --disable-xzdec \
        --disable-lzmadec \
        --disable-lzmainfo \
        --disable-lzma-links \
        --disable-scripts \
        --disable-doc \
        --disable-nls \
        --disable-rpath \
        --with-pic \
        > "$B/configure.log" 2>&1 || {
            echo "!!! xz configure failed, tail of log:"
            tail -80 "$B/configure.log"
            exit 1
        }

    make -j"$(nproc)" >> "$B/build.log" 2>&1 || {
        echo "!!! xz make failed, tail of log:"
        tail -80 "$B/build.log"
        exit 1
    }
    make install >> "$B/build.log" 2>&1

    if [ ! -f "$INSTALL_PREFIX/lib/liblzma.a" ]; then
        echo "ERROR: liblzma.a 没装到 $INSTALL_PREFIX/lib/"
        find "$INSTALL_PREFIX" -name 'liblzma*' | sed 's/^/  /'
        exit 1
    fi
    echo "    ok: $INSTALL_PREFIX/lib/liblzma.a"
}
[ $ENABLE_XZ -eq 1 ] && build_xz

# ================================================================
# 5. 编译 zstd (静态, 可选)
# ================================================================
build_zstd() {
    echo "==> build zstd (static)"
    local B="$THIRDPARTY/build-zstd"
    [ $RESET -eq 1 ] && rm -rf "$B"
    mkdir -p "$B" && cd "$B"

    "$OHOS_CMAKE" "$ZSTD_SRC/build/cmake" -GNinja \
        -DCMAKE_MAKE_PROGRAM="$OHOS_NINJA" \
        -DCMAKE_TOOLCHAIN_FILE="$OHOS_TOOLCHAIN" \
        -DOHOS_ARCH="$OHOS_ARCH" \
        -DOHOS_PLATFORM=OHOS \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
        -DZSTD_BUILD_STATIC=ON \
        -DZSTD_BUILD_SHARED=OFF \
        -DZSTD_BUILD_PROGRAMS=OFF \
        -DZSTD_BUILD_TESTS=OFF \
        -DZSTD_BUILD_CONTRIB=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        > "$B/configure.log" 2>&1

    "$OHOS_NINJA" -j"$(nproc)"
    "$OHOS_NINJA" install
}
[ $ENABLE_ZSTD -eq 1 ] && build_zstd

# ================================================================
# 6. 编译 libarchive + bsdtar -> libtar.so
# ================================================================
echo "==> build libarchive + libtar.so"
ARCH_BUILD="$THIRDPARTY/build-libarchive"
[ $RESET -eq 1 ] && rm -rf "$ARCH_BUILD"
mkdir -p "$ARCH_BUILD" && cd "$ARCH_BUILD"

WARN_FLAGS=$(cat <<'EOF' | tr '\n' ' '
-Wno-unused-command-line-argument
-Wno-format
-Wno-format-security
-Wno-error=format-security
-Wno-deprecated-declarations
-Wno-unused-function
-Wno-unused-variable
-Wno-unused-but-set-variable
-Wno-string-plus-int
-Wno-macro-redefined
EOF
)

XZ_ARG=$([ $ENABLE_XZ -eq 1 ] && echo "-DENABLE_LZMA=ON" || echo "-DENABLE_LZMA=OFF")
ZSTD_ARG=$([ $ENABLE_ZSTD -eq 1 ] && echo "-DENABLE_ZSTD=ON" || echo "-DENABLE_ZSTD=OFF")

# 让 find_package(ZLIB) 精准命中我们编好的 static lib
CMAKE_EXTRA=(
    -DZLIB_LIBRARY="$INSTALL_PREFIX/lib/libz.a"
    -DZLIB_INCLUDE_DIR="$INSTALL_PREFIX/include"
)
if [ $ENABLE_XZ -eq 1 ]; then
    CMAKE_EXTRA+=(
        -DLIBLZMA_LIBRARY="$INSTALL_PREFIX/lib/liblzma.a"
        -DLIBLZMA_INCLUDE_DIR="$INSTALL_PREFIX/include"
    )
fi
if [ $ENABLE_ZSTD -eq 1 ]; then
    CMAKE_EXTRA+=(
        -DZSTD_LIBRARY="$INSTALL_PREFIX/lib/libzstd.a"
        -DZSTD_INCLUDE_DIR="$INSTALL_PREFIX/include"
    )
fi

"$OHOS_CMAKE" "$ARCH_SRC" -GNinja \
    -DCMAKE_MAKE_PROGRAM="$OHOS_NINJA" \
    -DCMAKE_TOOLCHAIN_FILE="$OHOS_TOOLCHAIN" \
    -DOHOS_ARCH="$OHOS_ARCH" \
    -DOHOS_PLATFORM=OHOS \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
    -DCMAKE_PREFIX_PATH="$INSTALL_PREFIX" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DENABLE_TEST=OFF \
    -DENABLE_INSTALL=OFF \
    -DENABLE_TAR=ON \
    -DENABLE_TAR_SHARED=OFF \
    -DENABLE_CPIO=OFF \
    -DENABLE_CAT=OFF \
    -DENABLE_UNZIP=OFF \
    -DENABLE_ACL=OFF \
    -DENABLE_XATTR=OFF \
    -DENABLE_ICONV=OFF \
    -DENABLE_OPENSSL=OFF \
    -DENABLE_LIBB2=OFF \
    -DENABLE_LZ4=OFF \
    -DENABLE_BZIP2=OFF \
    -DENABLE_ZLIB=ON \
    $XZ_ARG \
    $ZSTD_ARG \
    "${CMAKE_EXTRA[@]}" \
    -DCMAKE_C_FLAGS="$WARN_FLAGS -I$INSTALL_PREFIX/include" \
    -DCMAKE_CXX_FLAGS="$WARN_FLAGS -I$INSTALL_PREFIX/include"

LOG_DIR=$ROOT/logs
mkdir -p "$LOG_DIR"
TS=$(date +%Y%m%d_%H%M%S)
BUILD_LOG="$LOG_DIR/libtar_${TS}.log"
LATEST_LOG="$LOG_DIR/libtar_latest.log"

echo "==> ninja bsdtar (log: $BUILD_LOG)"
set +e
"$OHOS_NINJA" bsdtar -j"$(nproc)" 2>&1 | tee "$BUILD_LOG"
NINJA_RC=${PIPESTATUS[0]}
set -e
ln -sfn "$BUILD_LOG" "$LATEST_LOG"

if [ "$NINJA_RC" -ne 0 ]; then
    echo ""
    echo "==== 第一段 FAILED ===="
    awk '/^FAILED:/{f=1} f{print; if(/^\[[0-9]+\/[0-9]+\]/ && !/^FAILED:/) exit}' \
        "$BUILD_LOG" | head -120
    echo ""
    echo "==== error: 行汇总 (前 50) ===="
    grep -nE 'error:|FAILED:' "$BUILD_LOG" | head -50
    exit 1
fi

# ================================================================
# 7. 收集产物
# ================================================================
SO_PATH=$(find "$ARCH_BUILD" -name 'libtar.so' -type f | head -1)
if [ -z "$SO_PATH" ]; then
    echo "ERROR: libtar.so not found under $ARCH_BUILD"
    find "$ARCH_BUILD" -type f \( -name '*.so' -o -name 'bsdtar*' \) | sed 's/^/  /'
    exit 1
fi

cp "$SO_PATH" "$OUT/libtar.so"
chmod 644 "$OUT/libtar.so"

# ================================================================
# 8. 报告
# ================================================================
LLVM_BIN="$OHOS_SDK/native/llvm/bin"

echo ""
echo "============================================================"
echo "  libtar.so built"
ls -lh "$OUT/libtar.so"

if [ -x "$LLVM_BIN/llvm-readelf" ]; then
    echo ""
    echo "  ELF info:"
    "$LLVM_BIN/llvm-readelf" -h "$OUT/libtar.so" \
        | grep -E 'Class|Machine|Type' | sed 's/^/    /'
    echo ""
    echo "  NEEDED (外部依赖):"
    "$LLVM_BIN/llvm-readelf" -d "$OUT/libtar.so" \
        | grep -E 'NEEDED|SONAME|RUNPATH|RPATH' | sed 's/^/    /' || true
    echo ""
    echo "  exported entry:"
    EXPORTS=$("$LLVM_BIN/llvm-nm" -D --defined-only "$OUT/libtar.so" 2>/dev/null \
        | grep -w bsdtar_main || true)
    if [ -n "$EXPORTS" ]; then
        echo "$EXPORTS" | sed 's/^/    /'
    else
        echo "    !!! bsdtar_main NOT exported. Patch 失败?"
        echo "    检查 $ARCH_SRC/tar/bsdtar.c 是否包含 bsdtar_main"
        exit 1
    fi
    echo ""
    echo "  chksum:"
    md5sum "$OUT/libtar.so"
fi
echo "============================================================"

END=$(date +%s%N)
SEC=$(( (END-START)/1000000000 ))
MS=$(( ((END-START)/1000000)%1000 ))
echo ""
echo "  done in ${SEC}.${MS}s"
echo "============================================================"