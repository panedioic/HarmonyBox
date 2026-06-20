#!/usr/bin/env bash
# Box64 + BOX32 .so build for HarmonyOS HAP integration.
#
# 输出: libbox64.so, 导出 box64_run(argc, argv, env)
#
# HAP NAPI 调用契约:
#   1. fork()
#   2. 子进程 dlopen("libbox64.so", RTLD_NOW|RTLD_GLOBAL)
#   3. dlsym(handle, "box64_run")
#   4. box64_run(argc, argv, env)
#
# 用法:
#   bash build.sh
#   bash build.sh --no-reset    # 增量 (不 reset 源码)
#
# 环境变量:
#   OHOS_SDK         默认 /workspace/ohos-sdk/linux

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

ROOT=/workspace/dev/HarmonyBox
BOX64=$ROOT/box64
BUILD=$ROOT/build_box64
OUT=$ROOT/out

THIRD_PARTY=$ROOT/thirdparty
mkdir -p "$THIRD_PARTY"

RESET_SOURCE=1
for arg in "$@"; do
    case "$arg" in
        --reset-source) RESET_SOURCE=1 ;;
        --no-reset)     RESET_SOURCE=0 ;;
        *) echo "未知参数: $arg"; exit 1 ;;
    esac
done

# ================================================================
# 1. 源码与工具链检查
# ================================================================
if [ ! -d "$BOX64" ]; then
    echo "ERROR: box64 源码不存在: $BOX64"
    echo "       git clone https://github.com/ptitSeb/box64.git $BOX64"
    exit 1
fi
for f in "$OHOS_TOOLCHAIN" "$OHOS_CMAKE" "$OHOS_NINJA"; do
    if [ ! -e "$f" ]; then
        echo "ERROR: 找不到 $f"
        exit 1
    fi
done

echo "==> environment (BOX32=ON, output libbox64.so)"
echo "    OHOS_SDK   = $OHOS_SDK"
echo "    OHOS_ARCH  = $OHOS_ARCH"
echo "    box64 src  = $BOX64"
echo "    build dir  = $BUILD"
echo "    out  dir   = $OUT"

# ================================================================
# 2. 清理
# ================================================================
if [ $RESET_SOURCE -eq 1 ]; then
    echo "==> git reset --hard (清除以前补丁残留)"
    cd "$BOX64"
    git reset --hard
    git clean -fdx
    cd - > /dev/null
fi

if [ -d "$BUILD" ]; then
    echo "==> 清理 $BUILD"
    rm -rf "$BUILD"
fi
mkdir -p "$BUILD"

# ================================================================
# 3. 应用 patches
# ================================================================
PATCH_SCRIPT="$(dirname "$(readlink -f "$0")")/patches.sh"
if [ ! -f "$PATCH_SCRIPT" ]; then
    echo "ERROR: 找不到 patches.sh: $PATCH_SCRIPT"
    exit 1
fi

if [ $RESET_SOURCE -eq 0 ]; then
    echo "==> --no-reset, 跳过 patch (依赖现有源码状态)"
else
    echo "==> apply patches"
    BOX64="$BOX64" bash "$PATCH_SCRIPT"
fi

# ================================================================
# 4. CMake 配置 (BOX32=ON, SHARED)
# ================================================================
echo "==> CMake configure (BOX32=ON, SHARED)"
cd "$BUILD"

WARN_FLAGS=$(cat <<'EOF' | tr '\n' ' '
-Wno-macro-redefined
-Wno-unused-command-line-argument
-Wno-format
-Wno-format-security
-Wno-error=format-security
-Wno-deprecated-declarations
-Wno-unused-function
-Wno-unused-variable
-Wno-unused-but-set-variable
-Wno-int-conversion
-Wno-error=int-conversion
-Wno-incompatible-pointer-types
-Wno-implicit-function-declaration
-Wno-string-plus-int
-Wno-array-bounds
-Wno-ignored-pragmas
EOF
)

# patch_53 已经把 add_executable 改成 add_library SHARED, target 名仍是 box64.
# -DBUILD_SHARED_LIBS=ON 用于其它 add_library() 默认走 SHARED, 保险.
"$OHOS_CMAKE" "$BOX64" \
    -GNinja \
    -DCMAKE_MAKE_PROGRAM="$OHOS_NINJA" \
    -DCMAKE_TOOLCHAIN_FILE="$OHOS_TOOLCHAIN" \
    -DOHOS_ARCH="$OHOS_ARCH" \
    -DOHOS_PLATFORM=OHOS \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DARM_DYNAREC=ON \
    -DBOX32=ON \
    -DGENERIC_ARM=1 \
    -DNOLOADADDR=1 \
    -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_C_FLAGS="$WARN_FLAGS" \
    -DCMAKE_CXX_FLAGS="$WARN_FLAGS"

# ================================================================
# 5. 编译
# ================================================================
LOG_DIR=$ROOT/logs
mkdir -p "$LOG_DIR"
TS=$(date +%Y%m%d_%H%M%S)
BUILD_LOG="$LOG_DIR/box64_so_${TS}.log"
LATEST_LOG="$LOG_DIR/box64_so_latest.log"

echo "==> ninja box64 (target produces libbox64.so, log: $BUILD_LOG)"

set +e
"$OHOS_NINJA" box64 -j"$(nproc)" 2>&1 | tee "$BUILD_LOG"
NINJA_RC=${PIPESTATUS[0]}
set -e

ln -sfn "$BUILD_LOG" "$LATEST_LOG"

if [ "$NINJA_RC" -ne 0 ]; then
    echo ""
    echo "============================================================"
    echo "  编译失败 (exit=$NINJA_RC)"
    echo "  完整日志: $BUILD_LOG"
    echo "============================================================"
    echo ""
    echo "==== 第一段 FAILED ===="
    awk '/^FAILED:/{f=1} f{print; if(/^\[[0-9]+\/[0-9]+\]/ && !/^FAILED:/) exit}' \
        "$BUILD_LOG" | head -120
    echo ""
    echo "==== error: 行汇总 (前 50) ===="
    grep -nE 'error:|FAILED:' "$BUILD_LOG" | head -50
    echo ""
    echo "提示: 把上面这两段贴回去, 给 patches.sh 增量加 patch."
    exit 1
fi

echo "==> 编译成功"

# ================================================================
# 6. 输出与导出符号检查
# ================================================================
mkdir -p "$OUT"
SO_PATH="$BUILD/libbox64.so"
if [ ! -f "$SO_PATH" ]; then
    SO_PATH=$(find "$BUILD" -maxdepth 3 -name 'libbox64.so' -type f | head -1)
fi
if [ -z "$SO_PATH" ] || [ ! -f "$SO_PATH" ]; then
    echo "ERROR: 找不到 libbox64.so"
    echo "  build dir 实际产物:"
    find "$BUILD" -maxdepth 3 -type f \( -name '*.so' -o -name 'box64' \) \
        | sed 's/^/    /'
    exit 1
fi
cp "$SO_PATH" "$OUT/libbox64.so"
chmod 644 "$OUT/libbox64.so"

LLVM_BIN="$OHOS_SDK/native/llvm/bin"

echo ""
echo "============================================================"
echo "  libbox64.so built (BOX32=ON)"
echo "  output: $OUT/libbox64.so"
ls -lh "$OUT/libbox64.so"

if [ -x "$LLVM_BIN/llvm-readelf" ]; then
    echo ""
    echo "  ELF info:"
    "$LLVM_BIN/llvm-readelf" -h "$OUT/libbox64.so" \
        | grep -E 'Class|Machine|Type' | sed 's/^/    /' || true
    echo ""
    echo "  SONAME / NEEDED:"
    "$LLVM_BIN/llvm-readelf" -d "$OUT/libbox64.so" \
        | grep -E 'NEEDED|SONAME|RUNPATH|RPATH' | sed 's/^/    /' || true
    echo ""
    echo "  exported V4 entries (must include box64_run):"
    EXPORTS=$("$LLVM_BIN/llvm-nm" -D --defined-only "$OUT/libbox64.so" 2>/dev/null \
        | grep -wE 'box64_run|box64_main|box64_install_sigsys_fallback' || true)
    if [ -n "$EXPORTS" ]; then
        echo "$EXPORTS" | sed 's/^/    /'
    else
        echo "    WARN: 没找到 box64_run, 检查 patch 50-53 是否成功"
    fi
    echo ""
    echo "  chksum:"
    md5sum "$OUT/libbox64.so"
fi
echo "============================================================"

END=$(date +%s%N)
SEC=$(( (END-START)/1000000000 ))
MS=$(( ((END-START)/1000000)%1000 ))
echo ""
echo "  done in ${SEC}.${MS}s"
echo "============================================================"