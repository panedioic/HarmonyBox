#!/usr/bin/env bash
# Box64 source patches for HarmonyOS / OHOS musl.
#
# 用法:
#   被 build_box64_ohos_clean.sh 调用,需 BOX64 环境变量指向源码目录.
#   也可以独立运行:  BOX64=~/HarmonyBox/box64 bash patches.sh
#
# 设计:
#   - 每条 patch 一个函数, 自带原因说明
#   - 通过源码内标记注释判断是否已打过, 幂等
#   - 任一条失败立即退出 (set -e), 由 build.sh 统一处理

set -e

: "${BOX64:?BOX64 环境变量未设置 (应指向 box64 源码目录)}"

if [ ! -d "$BOX64" ]; then
    echo "ERROR: BOX64 目录不存在: $BOX64"
    exit 1
fi

ROOT=~/HarmonyBox
THIRD_PARTY=$ROOT/thirdparty
mkdir -p "$THIRD_PARTY"

# ---------- 工具 ----------

_patch_header() {
    # $1 编号  $2 文件  $3 一句话描述
    printf '    [#%-2s] %-40s  %s\n' "$1" "$2" "$3"
}

_already() {
    # $1 文件  $2 标记
    [ -f "$1" ] && grep -q "$2" "$1"
}

_clone_shallow() {
    # $1 url  $2 dest
    local url="$1" dest="$2"
    if [ -d "$dest/.git" ]; then
        return 0
    fi
    if [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
        # 不是 git 仓库但又非空, 不动
        return 0
    fi
    rm -rf "$dest"
    git clone --depth=1 "$url" "$dest"
}

# ================================================================
# Patch 01 — src/os/os_linux.c: musl mallopt 兼容
# ================================================================
# 报错:
#   error: use of undeclared identifier 'M_ARENA_TEST'
#   error: use of undeclared identifier 'M_ARENA_MAX'
#   error: use of undeclared identifier 'M_MMAP_THRESHOLD'
#
# 原因:
#   M_ARENA_* 与 M_MMAP_THRESHOLD 是 glibc ptmalloc 的私有调参常量,
#   musl 的 malloc 不识别也不暴露这些符号.
#
# 修法:
#   用 #ifdef 包裹这三行 mallopt 调用; 未定义就跳过.
#   musl 下这些调参没意义, 跳过对 box64 功能无影响.
patch_01_mallopt() {
    local f="$BOX64/src/os/os_linux.c"
    local mark='OHOS_PATCH_MALLOPT'

    [ -f "$f" ] || { _patch_header 01 "(skip) os_linux.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 01 "src/os/os_linux.c" "mallopt — already patched"
        return 0
    fi
    _patch_header 01 "src/os/os_linux.c" "wrap M_ARENA_*/M_MMAP_THRESHOLD with #ifdef"

    sed -i "1i\\
/* $mark */" "$f"

    sed -i \
        -e 's|^\(\s*\)mallopt(M_ARENA_TEST, 2);|#ifdef M_ARENA_TEST\n\1mallopt(M_ARENA_TEST, 2);\n#endif|' \
        -e 's|^\(\s*\)mallopt(M_ARENA_MAX, 2);|#ifdef M_ARENA_MAX\n\1mallopt(M_ARENA_MAX, 2);\n#endif|' \
        -e 's|^\(\s*\)mallopt(M_MMAP_THRESHOLD, 128\*1024);|#ifdef M_MMAP_THRESHOLD\n\1mallopt(M_MMAP_THRESHOLD, 128*1024);\n#endif|' \
        "$f"
}

# ================================================================
# Patch 02 — src/libtools/signals.c: glibc-only NP 互斥锁初始化器
# ================================================================
# 报错:
#   error: use of undeclared identifier 'PTHREAD_ERRORCHECK_MUTEX_INITIALIZER_NP'
#
# 原因:
#   PTHREAD_ERRORCHECK_MUTEX_INITIALIZER_NP / RECURSIVE_MUTEX_INITIALIZER_NP
#   是 glibc 的私有静态初始化器, musl 不提供.
#
# 修法:
#   在 signals.c 顶部为这两个宏提供 fallback 定义,
#   值用普通 PTHREAD_MUTEX_INITIALIZER. errorcheck/recursive 行为差异
#   只影响错误检查/重入策略, 对 box64 信号路径没有功能影响.
patch_02_pthread_np() {
    local f="$BOX64/src/libtools/signals.c"
    local mark='OHOS_PATCH_PTHREAD_NP'

    [ -f "$f" ] || { _patch_header 02 "(skip) signals.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 02 "src/libtools/signals.c" "pthread NP init — already patched"
        return 0
    fi
    _patch_header 02 "src/libtools/signals.c" "fallback for ERRORCHECK/RECURSIVE_*_NP"

    sed -i "1i\\
/* $mark */\\
#include <pthread.h>\\
#ifndef PTHREAD_ERRORCHECK_MUTEX_INITIALIZER_NP\\
#define PTHREAD_ERRORCHECK_MUTEX_INITIALIZER_NP PTHREAD_MUTEX_INITIALIZER\\
#endif\\
#ifndef PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP\\
#define PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP PTHREAD_MUTEX_INITIALIZER\\
#endif" "$f"
}

# ================================================================
# Patch 03 — fts.h / fts_*: 集成 musl-fts
# ================================================================
# 报错:
#   fatal error: 'fts.h' file not found
#   (出现在 src/libtools/auxval.c, src/libtools/myalign.c 等)
#
# 原因:
#   fts(3) 是 BSD 起源的目录遍历 API. glibc 提供了 fts.h / fts_open /
#   fts_read 等, musl 没有. box64 在多个地方包含 <fts.h>.
#
# 修法:
#   1. 浅克隆 https://github.com/void-linux/musl-fts
#   2. 把 fts.h 放到 src/include/fts.h         (满足 #include <fts.h>)
#   3. 把 fts.c 复制为 src/musl_fts.c          (提供实现)
#   4. 在 CMakeLists.txt 末尾追加 target_sources, 把 musl_fts.c 编进 box64
#
# 幂等性:
#   - 文件存在则跳过复制
#   - CMakeLists.txt 用唯一标记 OHOS_PATCH_FTS_TARGET 防重复
patch_03_fts() {
    local fts_repo="$THIRD_PARTY/musl-fts"
    local hdr_dst="$BOX64/src/include/fts.h"
    local src_dst="$BOX64/src/musl_fts.c"
    local cm="$BOX64/CMakeLists.txt"
    local mark='OHOS_PATCH_FTS_TARGET'

    _patch_header 03 "src/include/fts.h + src/musl_fts.c" "integrate musl-fts"

    _clone_shallow https://github.com/void-linux/musl-fts.git "$fts_repo"

    if [ ! -f "$fts_repo/fts.h" ] || [ ! -f "$fts_repo/fts.c" ]; then
        echo "    [#03] ERROR: musl-fts 源码不完整: $fts_repo"
        return 1
    fi

    if [ ! -f "$hdr_dst" ]; then
        cp "$fts_repo/fts.h" "$hdr_dst"
        echo "    [#03]   + $hdr_dst"
    fi
    if [ ! -f "$src_dst" ]; then
        cp "$fts_repo/fts.c" "$src_dst"
        echo "    [#03]   + $src_dst"
    fi

    if _already "$cm" "$mark"; then
        echo "    [#03]   CMakeLists.txt — already patched"
    else
        echo "    [#03]   append target_sources to CMakeLists.txt"
        cat >> "$cm" << EOF_FTS

# $mark ====================================
if(TARGET box64)
    target_sources(box64 PRIVATE \${CMAKE_SOURCE_DIR}/src/musl_fts.c)
endif()
# =========================================
EOF_FTS
    fi
}

# ================================================================
# Patch 04 — src/include/myalign.h: __sigset_t 在 musl 必须带 struct 标签
# ================================================================
# 报错:
#   error: must use 'struct' tag to refer to type '__sigset_t'
#       __sigset_t       __saved_mask;
#       ^
#       struct
#
# 原因:
#   glibc 把内部类型 __sigset_t 用 typedef 暴露成无标签类型, 可裸用.
#   musl 只暴露带 struct 标签的形式, 必须写 'struct __sigset_t' 或者
#   直接用 POSIX 公开类型 sigset_t (二者实现等价).
#
# 修法:
#   把 myalign.h 里的 '__sigset_t __saved_mask' 换成 'sigset_t __saved_mask'.
#   sigset_t 是 POSIX 标准类型, glibc/musl 都有, 不会再出兼容性问题.
patch_04_sigset_t() {
    local f="$BOX64/src/include/myalign.h"
    local mark='OHOS_PATCH_SIGSET_T'

    [ -f "$f" ] || { _patch_header 04 "(skip) myalign.h not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 04 "src/include/myalign.h" "__sigset_t — already patched"
        return 0
    fi
    _patch_header 04 "src/include/myalign.h" "__sigset_t -> sigset_t"

    sed -i "1i\\
/* $mark */" "$f"
    sed -i 's/^\(\s*\)__sigset_t\(\s\+__saved_mask\)/\1sigset_t\2/' "$f"
}

# ================================================================
# Patch 05 — src/libtools/threads.c: 删除与 musl 冲突的 cleanup 本地声明
# ================================================================
# 报错:
#   error: conflicting types for '_pthread_cleanup_push'
#   error: conflicting types for '_pthread_cleanup_pop'
#
# 原因:
#   box64 在 threads.c 顶部为 _pthread_cleanup_push / _pthread_cleanup_pop
#   写了一份"自定义"的前向声明, 想直接调用 glibc 内部 NPTL 实现.
#   musl 的 <pthread.h> 也声明了这俩内部函数, 但参数/返回类型不一样,
#   两份声明撞车, 编译失败.
#
# 修法:
#   把 threads.c 里这两行手写的前向声明删掉, 直接用 musl <pthread.h>
#   暴露的版本. 调用站点的实参类型已经匹配 musl, 不需要改动.
patch_05_pthread_cleanup() {
    local f="$BOX64/src/libtools/threads.c"
    local mark='OHOS_PATCH_PTHREAD_CLEANUP'

    [ -f "$f" ] || { _patch_header 05 "(skip) threads.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 05 "src/libtools/threads.c" "cleanup decls — already patched"
        return 0
    fi
    _patch_header 05 "src/libtools/threads.c" "drop conflicting _pthread_cleanup_* decls"

    sed -i "1i\\
/* $mark */" "$f"

    # 行尾可能带 // 注释, 用宽松匹配: 行内出现该函数名声明且以 ); 结尾即删
    sed -i \
        -e '/^[[:space:]]*void[[:space:]]\+_pthread_cleanup_push[[:space:]]*(.*);/d' \
        -e '/^[[:space:]]*void[[:space:]]\+_pthread_cleanup_pop[[:space:]]*(.*);/d' \
        "$f"
}

# ================================================================
# Patch 06 — obstack.h / obstack_*: 集成 musl-obstack
# ================================================================
# 报错:
#   fatal error: 'obstack.h' file not found
#       (出现在 src/libtools/obstack.c, 后续可能还有 obstack_* 链接错误)
#
# 原因:
#   obstack(3) 是 GNU libc 提供的"对象栈"分配器, musl 不提供
#   obstack.h 头文件, 也不提供 _obstack_begin / _obstack_newchunk
#   等运行时实现.
#
# 修法:
#   照搬 fts 的做法:
#   1. 浅克隆 https://github.com/void-linux/musl-obstack
#   2. obstack.h 放到 src/include/obstack.h    (满足 #include <obstack.h>)
#   3. obstack.c 复制为 src/musl_obstack.c     (提供运行时符号)
#   4. CMakeLists.txt 里 target_sources 把 musl_obstack.c 加入 box64
#
# 注:
#   musl-obstack 的 obstack.c 可能 #include "config.h", 如果之后报缺
#   config.h, 再加 patch 07 提供最小桩.
patch_06_obstack() {
    local repo="$THIRD_PARTY/musl-obstack"
    local hdr_dst="$BOX64/src/include/obstack.h"
    local src_dst="$BOX64/src/musl_obstack.c"
    local cm="$BOX64/CMakeLists.txt"
    local mark='OHOS_PATCH_OBSTACK_TARGET'

    _patch_header 06 "src/include/obstack.h + src/musl_obstack.c" "integrate musl-obstack"

    _clone_shallow https://github.com/void-linux/musl-obstack.git "$repo"

    if [ ! -f "$repo/obstack.h" ] || [ ! -f "$repo/obstack.c" ]; then
        echo "    [#06] ERROR: musl-obstack 源码不完整: $repo"
        return 1
    fi

    if [ ! -f "$hdr_dst" ]; then
        cp "$repo/obstack.h" "$hdr_dst"
        echo "    [#06]   + $hdr_dst"
    fi
    if [ ! -f "$src_dst" ]; then
        cp "$repo/obstack.c" "$src_dst"
        echo "    [#06]   + $src_dst"
    fi

    if _already "$cm" "$mark"; then
        echo "    [#06]   CMakeLists.txt — already patched"
    else
        echo "    [#06]   append target_sources to CMakeLists.txt"
        cat >> "$cm" << EOF_OBS

# $mark ====================================
if(TARGET box64)
    target_sources(box64 PRIVATE \${CMAKE_SOURCE_DIR}/src/musl_obstack.c)
endif()
# =========================================
EOF_OBS
    fi
}

# ================================================================
# Patch 07 — src/include/error.h: musl 不提供 <error.h>, 给最小 stub
# ================================================================
# 报错:
#   fatal error: 'error.h' file not found
#       (出现在 src/wrapped/wrappedlibc.c)
#
# 原因:
#   error(3) / error_at_line(3) 是 glibc 的 GNU 扩展, 用于命令行
#   工具风格的报错+退出. musl 不提供 <error.h>.
#
# 修法:
#   写一份纯头文件的 stub: 把 error()/error_at_line() 实现为 inline
#   函数, 内部用 vfprintf/strerror/exit. 行为和 glibc 等价, 不需要
#   单独的实现 .c 文件; 也不会引入新的链接依赖.
#
#   再放一个 musl_error.c 提供 error_message_count / error_one_per_line
#   / error_print_progname 这三个数据符号 (GNU error.h 文档要求, 个别
#   下游代码会读它们; box64 自己不读, 但同样集成进来零成本).
patch_07_error_h() {
    local hdr="$BOX64/src/include/error.h"
    local src="$BOX64/src/musl_error.c"
    local cm="$BOX64/CMakeLists.txt"
    local mark='OHOS_PATCH_ERROR_H_TARGET'

    _patch_header 07 "src/include/error.h + src/musl_error.c" "GNU <error.h> stub"

    if [ ! -f "$hdr" ]; then
        cat > "$hdr" << 'EOF_ERROR_H'
/*
 * Minimal <error.h> stub for OHOS musl.
 * Provides GNU error(3) / error_at_line(3) inline.
 */
#ifndef BOX64_OHOS_ERROR_H
#define BOX64_OHOS_ERROR_H

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <errno.h>

#ifdef __cplusplus
extern "C" {
#endif

extern unsigned int error_message_count;
extern int          error_one_per_line;
extern void       (*error_print_progname)(void);

static inline void error(int status, int errnum, const char *fmt, ...)
{
    va_list ap;
    fflush(stdout);
    if (error_print_progname) error_print_progname();
    else                      fputs("box64: ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    if (errnum) fprintf(stderr, ": %s", strerror(errnum));
    fputc('\n', stderr);
    error_message_count++;
    if (status) exit(status);
}

static inline void error_at_line(int status, int errnum,
                                 const char *fname, unsigned int lineno,
                                 const char *fmt, ...)
{
    va_list ap;
    fflush(stdout);
    fprintf(stderr, "%s:%u: ", fname ? fname : "?", lineno);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    if (errnum) fprintf(stderr, ": %s", strerror(errnum));
    fputc('\n', stderr);
    error_message_count++;
    if (status) exit(status);
}

#ifdef __cplusplus
}
#endif

#endif /* BOX64_OHOS_ERROR_H */
EOF_ERROR_H
        echo "    [#07]   + $hdr"
    fi

    if [ ! -f "$src" ]; then
        cat > "$src" << 'EOF_ERROR_C'
/* Data symbols required by GNU <error.h> contract. */
#include <stddef.h>
unsigned int error_message_count = 0;
int          error_one_per_line  = 0;
void       (*error_print_progname)(void) = NULL;
EOF_ERROR_C
        echo "    [#07]   + $src"
    fi

    if _already "$cm" "$mark"; then
        echo "    [#07]   CMakeLists.txt — already patched"
    else
        echo "    [#07]   append target_sources to CMakeLists.txt"
        cat >> "$cm" << EOF_ERR_CM

# $mark ====================================
if(TARGET box64)
    target_sources(box64 PRIVATE \${CMAKE_SOURCE_DIR}/src/musl_error.c)
endif()
# =========================================
EOF_ERR_CM
    fi
}

# ================================================================
# Patch 08 — src/wrapped/wrappedlibdl.c: glibc dlinfo() 常量
# ================================================================
# 报错:
#   error: use of undeclared identifier 'RTLD_DL_SYMENT'
#   error: use of undeclared identifier 'RTLD_DL_LINKMAP'
#
# 原因:
#   RTLD_DL_SYMENT / RTLD_DL_LINKMAP 是 glibc 的 dlinfo(3) 请求码,
#   定义在 glibc 私有的 <dlfcn.h> 段里. musl 整体不实现 dlinfo, 自然
#   也不暴露这俩宏.
#
#   box64 用它们来 wrap dlinfo() 调用, 让 guest 能查询动态库符号项 /
#   link map. 编译期需要这俩宏存在, 运行期实际调用 dlinfo() 时, 我们
#   将提供一个 weak stub 返回 -ENOSYS (后续在 musl_compat.c 里加).
#
# 修法 (编译期):
#   在 wrappedlibdl.c 顶部为这两个宏提供 fallback 数值定义.
#   值参考 glibc <bits/dlfcn.h>:
#       RTLD_DI_LINKMAP   = 2   -> RTLD_DL_LINKMAP
#       RTLD_DI_TLS_MODID = 9
#       RTLD_DI_TLS_DATA  = 10
#   实际 box64 只用了 RTLD_DL_SYMENT / RTLD_DL_LINKMAP, 给同样的整数
#   值就够编译通过. 运行期由 dlinfo() stub 直接返回 ENOSYS.
patch_08_dlinfo_consts() {
    local f="$BOX64/src/wrapped/wrappedlibdl.c"
    local mark='OHOS_PATCH_DLINFO_CONSTS'

    [ -f "$f" ] || { _patch_header 08 "(skip) wrappedlibdl.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 08 "src/wrapped/wrappedlibdl.c" "RTLD_DL_* — already patched"
        return 0
    fi
    _patch_header 08 "src/wrapped/wrappedlibdl.c" "fallback for RTLD_DL_SYMENT/LINKMAP"

    sed -i "1i\\
/* $mark */\\
#ifndef RTLD_DL_LINKMAP\\
#define RTLD_DL_LINKMAP 2\\
#endif\\
#ifndef RTLD_DL_SYMENT\\
#define RTLD_DL_SYMENT  1\\
#endif" "$f"
}

# ================================================================
# Patch 09 — src/wrapped/wrappedlibc.c: musl 兼容 (一锅端)
# ================================================================
# 报错(摘):
#   error: duplicate member 'fstat'/'stat'/'lstat'/'fopen'/'ftw'/...
#       (源自 musl 的 #define stat64 stat 之类宏, 跟 wrapper 表撞名)
#   error: use of undeclared identifier '__compar_d_fn_t'
#   error: indirection requires pointer operand ('int' invalid)
#       (lock.__data.__owner 之类 glibc 私有布局)
#   error: use of undeclared identifier 'PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP'
#   error: no member named '__data' in 'pthread_mutex_t'
#
# 修法 (4 步):
#   A) 文件顶部 prologue: 加 ctype/pthread 头, 补 __compar_d_fn_t typedef,
#      为 PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP 提供 fallback
#   B) 在每个 '#include "wrappercallback.h"' 之前: #undef 一批 *64 宏,
#      让 wrapper 表里的 stat / stat64 等成为不同符号名
#   C) 在每个 '#include "wrappercallback.h"' 之后: #define *64 = 非 *64,
#      让本文件后续直接调用 stat64() / fopen64() 等还能编译通过
#      (在 musl 上 *64 函数就是非 *64 的别名)
#   D) 把 lock.__data.__owner 这类 glibc 私有访问全部替换成 0
#
# 幂等性:
#   全部用唯一标记 OHOS_PATCH_WRAPPEDLIBC, 只打一次.
patch_09_wrappedlibc() {
    local f="$BOX64/src/wrapped/wrappedlibc.c"
    local mark='OHOS_PATCH_WRAPPEDLIBC'

    [ -f "$f" ] || { _patch_header 09 "(skip) wrappedlibc.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 09 "src/wrapped/wrappedlibc.c" "musl compat — already patched"
        return 0
    fi
    _patch_header 09 "src/wrapped/wrappedlibc.c" "prologue + wrap callback include + struct shim"

    # ---- A) 顶部 prologue ----
    sed -i "1i\\
/* $mark */\\
#include <ctype.h>\\
#include <pthread.h>\\
#ifndef PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP\\
#define PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP PTHREAD_MUTEX_INITIALIZER\\
#endif\\
#ifndef PTHREAD_ERRORCHECK_MUTEX_INITIALIZER_NP\\
#define PTHREAD_ERRORCHECK_MUTEX_INITIALIZER_NP PTHREAD_MUTEX_INITIALIZER\\
#endif\\
typedef int (*__compar_d_fn_t)(const void *, const void *, void *);\\
/* $mark END */" "$f"

    # ---- B) 在每个 include "wrappercallback.h" 之前 undef ----
    sed -i '/^#include "wrappercallback.h"/i\
/* OHOS_UNDEF_BEFORE_CB */\
#undef stat64\
#undef fstat64\
#undef lstat64\
#undef fstatat64\
#undef fopen64\
#undef ftw64\
#undef nftw64\
#undef scandir64\
#undef open64\
#undef mmap64\
/* OHOS_UNDEF_BEFORE_CB END */' "$f"

    # ---- C) 在每个 include "wrappercallback.h" 之后 redefine ----
    sed -i '/^#include "wrappercallback.h"/a\
/* OHOS_REDEF_AFTER_CB */\
#define stat64    stat\
#define fstat64   fstat\
#define lstat64   lstat\
#define fstatat64 fstatat\
#define fopen64   fopen\
#define ftw64     ftw\
#define nftw64    nftw\
#define scandir64 scandir\
#define open64    open\
#define mmap64    mmap\
/* OHOS_REDEF_AFTER_CB END */' "$f"

    # ---- D) glibc 私有 pthread_mutex_t 内部布局: 一律视为 0 ----
    sed -i \
        -e 's|lock\.__data\.__owner|0 /* musl: no __data.__owner */|g' \
        -e 's|lock\.__data\.__count|0 /* musl: no __data.__count */|g' \
        -e 's|lock\.__data\.__lock|0  /* musl: no __data.__lock  */|g' \
        "$f"
}

# ================================================================
# Patch 10 — src/wrapped/wrappedlibc.c: ctype 私有 + GNU sched.h 常量
# ================================================================
# 报错(本轮新增):
#   error: indirection requires pointer operand ('int' invalid)
#       *(__ctype_b_loc()) / __ctype_tolower_loc() / __ctype_toupper_loc()
#   error: use of undeclared identifier 'CLONE_NEWUSER'
#                                       'CLONE_VM' 'CLONE_VFORK' 'CLONE_SETTLS'
#
# 原因:
#   1) musl 的 <ctype.h> 不暴露 __ctype_*_loc() 系列 (glibc 私有). 没声明
#      时 clang 退化为 int 返回类型, 解引用直接编译失败.
#   2) musl 的 <sched.h> 把 CLONE_* 这一坨宏放在 _GNU_SOURCE 保护下;
#      clean baseline 没全局开 _GNU_SOURCE, 所以全部不可见.
#
# 修法:
#   - 文件最顶部 #ifndef _GNU_SOURCE / #define _GNU_SOURCE
#   - #include <sched.h>  让 CLONE_* 暴露
#   - 手写 __ctype_b_loc / tolower_loc / toupper_loc 三个函数声明
#     (运行期符号留给 musl_compat.c 提供 weak 实现)
#
# 注:
#   patch_09 已经在文件顶部插过一段, 这里再 1i 一次, 新内容会出现
#   在更靠前的位置, 不会冲突. 关键是 _GNU_SOURCE 必须先于任何
#   <sched.h> / 其它系统头展开.
patch_10_wrappedlibc_more() {
    local f="$BOX64/src/wrapped/wrappedlibc.c"
    local mark='OHOS_PATCH_WRAPPEDLIBC_MORE'

    [ -f "$f" ] || { _patch_header 10 "(skip) wrappedlibc.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 10 "src/wrapped/wrappedlibc.c" "ctype/CLONE — already patched"
        return 0
    fi
    _patch_header 10 "src/wrapped/wrappedlibc.c" "_GNU_SOURCE + sched.h + __ctype_*_loc decls"

    sed -i "1i\\
/* $mark */\\
#ifndef _GNU_SOURCE\\
#define _GNU_SOURCE\\
#endif\\
#include <sched.h>\\
extern const unsigned short **__ctype_b_loc(void);\\
extern const int **__ctype_tolower_loc(void);\\
extern const int **__ctype_toupper_loc(void);\\
/* $mark END */" "$f"
}

# ================================================================
# Patch 11 — src/include/config.h: 提供 autotools 风格的最小 config.h
# ================================================================
# 报错:
#   fatal error: 'config.h' file not found
#       (源自 src/musl_obstack.c, src/musl_fts.c)
#
# 原因:
#   musl-obstack 和 musl-fts 都是从 GNU autotools 项目剥离出来的,
#   源码顶部 '#include <config.h>'. config.h 是 autotools configure
#   阶段生成的产物, 列出 HAVE_* 探测结果. 我们没用 autotools, 没人
#   生成它.
#
# 修法:
#   手写一份最小 config.h 放到 src/include/. 内容是 OHOS musl 上
#   一定满足的 HAVE_* 列表 (dirent / fstatat / openat / dirfd 等
#   POSIX 接口都在). 这两份代码看到 HAVE_DIRENT_D_TYPE 之类的宏
#   被定义为 1, 就会走快路径; 没定义也只是走慢路径, 不影响功能.
#
# 注:
#   只对 musl-obstack / musl-fts 这两份外来代码有用. box64 自己的
#   .c 文件不会去 include <config.h>.
patch_11_config_h() {
    local hdr="$BOX64/src/include/config.h"

    if [ -f "$hdr" ] && grep -q 'BOX64_OHOS_MIN_CONFIG_H' "$hdr"; then
        _patch_header 11 "src/include/config.h" "minimal config.h — already patched"
        return 0
    fi

    _patch_header 11 "src/include/config.h" "minimal autotools-style config.h"

    cat > "$hdr" << 'EOF_CONFIG_H'
/*
 * Minimal config.h for musl-obstack and musl-fts on OHOS musl.
 * Hand-written substitute for what autotools' configure would produce.
 */
#ifndef BOX64_OHOS_MIN_CONFIG_H
#define BOX64_OHOS_MIN_CONFIG_H

/* --- standard headers --- */
#define HAVE_STDLIB_H        1
#define HAVE_STRING_H        1
#define HAVE_STRINGS_H       1
#define HAVE_UNISTD_H        1
#define HAVE_INTTYPES_H      1
#define HAVE_STDINT_H        1
#define HAVE_ERRNO_H         1
#define HAVE_FCNTL_H         1
#define HAVE_LIMITS_H        1
#define HAVE_MEMORY_H        1
#define HAVE_SYS_PARAM_H     1
#define HAVE_SYS_STAT_H      1
#define HAVE_SYS_TYPES_H     1
#define HAVE_DIRENT_H        1

/* --- functions / fields available on OHOS musl aarch64 --- */
#define HAVE_FSTATAT         1
#define HAVE_OPENAT          1
#define HAVE_FCHDIR          1
#define HAVE_DIRFD           1
#define HAVE_DIRENT_D_TYPE   1
#define HAVE_GETPAGESIZE     1
#define HAVE_MEMCPY          1
#define HAVE_MEMMOVE         1

/* --- generic macros some upstream projects expect --- */
#define STDC_HEADERS         1
#define _ALL_SOURCE          1

/* --- package strings (referenced by some upstream code) --- */
#define PACKAGE              "box64-ohos"
#define PACKAGE_NAME         "box64-ohos"
#define PACKAGE_VERSION      "1.0"
#define VERSION              "1.0"

#endif /* BOX64_OHOS_MIN_CONFIG_H */
EOF_CONFIG_H
}

# ================================================================
# Patch 12 — src/musl_compat.c: glibc-only 运行期符号 weak stub 一锅端
# ================================================================
# 报错(节选):
#   ld.lld: undefined symbol: __libc_malloc / __libc_free / __libc_calloc /
#                             __libc_realloc / __libc_memalign / dlinfo /
#                             pthread_*_affinity_np / pthread_mutexattr_*robust /
#                             obstack_vprintf / qsort_r / glob64 /
#                             scandirat / scandirat64 / __ctype_b_loc
#
# 原因:
#   这些都是 glibc 提供而 musl 不提供的符号. box64 的代码 (以及 musl-obstack
#   里) 直接引用了它们, 链接阶段 ld.lld 找不到实体 -> undefined symbol.
#
# 修法:
#   写一份 src/musl_compat.c, 用 weak 属性提供所有这些符号的兜底实现.
#   weak 的好处: 如果将来某个版本的 OHOS NDK / musl 补全了某个符号,
#   会自动覆盖我们的 stub, 不需要再改代码.
#
# 设计要点:
#   1. __libc_malloc 系列直接转发到 POSIX malloc/free/calloc/realloc/memalign
#   2. dlinfo 返回 -1 + errno=ENOSYS  (运行期 box64 走 fallback 路径)
#   3. pthread NP 扩展返回 ENOSYS 或 0  (CPU 亲和性等无法在沙箱里设置)
#   4. obstack_printf/vprintf 用 vsnprintf + obstack_grow 拼出来
#   5. qsort_r 用 thread-local 变量做跳板, 转给 qsort
#   6. glob64/globfree64 直接转给 glob/globfree (musl 上 off64_t == off_t)
#   7. scandirat/scandirat64 用 openat + fdopendir + readdir 手写
#   8. __ctype_b_loc 系列: 在 ctor 阶段填好 256 项表, 返回指向 +128 偏移的指针
#      (glibc 风格 -- 允许下标 -128..127)
patch_12_musl_compat() {
    local f="$BOX64/src/musl_compat.c"
    local cm="$BOX64/CMakeLists.txt"
    local mark='OHOS_PATCH_MUSL_COMPAT_TARGET'

    if [ -f "$f" ] && grep -q 'BOX64_OHOS_MUSL_COMPAT' "$f"; then
        _patch_header 12 "src/musl_compat.c" "weak symbol stubs — already patched"
    else
        _patch_header 12 "src/musl_compat.c" "weak stubs for glibc-only runtime symbols"
        cat > "$f" << 'EOF_MUSL_COMPAT'
/*
 * musl_compat.c — glibc-private symbol stubs for OHOS musl.
 *
 * All implementations are weak so that any future OHOS NDK update which
 * adds a real symbol will silently override these.
 */
#define _GNU_SOURCE
#define BOX64_OHOS_MUSL_COMPAT 1

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern void *memalign(size_t, size_t);  /* not in <stdlib.h> on musl */

/* ------------------------------------------------------------------
 * glibc-private __libc_* malloc family
 * ------------------------------------------------------------------ */
__attribute__((weak)) void *__libc_malloc (size_t s)            { return malloc(s); }
__attribute__((weak)) void  __libc_free   (void *p)             { free(p); }
__attribute__((weak)) void *__libc_calloc (size_t n, size_t s)  { return calloc(n, s); }
__attribute__((weak)) void *__libc_realloc(void *p, size_t s)   { return realloc(p, s); }
__attribute__((weak)) void *__libc_memalign(size_t a, size_t s) { return memalign(a, s); }
__attribute__((weak)) void *__libc_valloc (size_t s)
{
    return memalign(sysconf(_SC_PAGESIZE), s);
}
__attribute__((weak)) void *__libc_pvalloc(size_t s)
{
    long pg = sysconf(_SC_PAGESIZE);
    size_t r = (s + pg - 1) & ~(pg - 1);
    return memalign(pg, r);
}

/* ------------------------------------------------------------------
 * pthread NP extensions
 * ------------------------------------------------------------------ */
__attribute__((weak))
int pthread_attr_setaffinity_np(pthread_attr_t *a, size_t s, const void *c)
{ (void)a;(void)s;(void)c; return ENOSYS; }

__attribute__((weak))
int pthread_attr_getaffinity_np(const pthread_attr_t *a, size_t s, void *c)
{ (void)a;(void)s;(void)c; return ENOSYS; }

__attribute__((weak))
int pthread_getaffinity_np(pthread_t t, size_t s, void *c)
{ (void)t;(void)s;(void)c; return ENOSYS; }

__attribute__((weak))
int pthread_setaffinity_np(pthread_t t, size_t s, const void *c)
{ (void)t;(void)s;(void)c; return ENOSYS; }

__attribute__((weak))
int pthread_getattr_default_np(pthread_attr_t *a)
{ (void)a; return ENOSYS; }

__attribute__((weak))
int pthread_setattr_default_np(pthread_attr_t *a)
{ (void)a; return ENOSYS; }

__attribute__((weak))
int pthread_mutexattr_getrobust(const pthread_mutexattr_t *a, int *r)
{ (void)a; if (r) *r = 0; return 0; }

__attribute__((weak))
int pthread_mutexattr_setrobust(pthread_mutexattr_t *a, int r)
{ (void)a;(void)r; return 0; }

__attribute__((weak))
int pthread_mutexattr_getprioceiling(const pthread_mutexattr_t *a, int *p)
{ (void)a; if (p) *p = 0; return 0; }

__attribute__((weak))
int pthread_mutexattr_setprioceiling(pthread_mutexattr_t *a, int p)
{ (void)a;(void)p; return ENOSYS; }

/* ------------------------------------------------------------------
 * dlinfo — musl doesn't ship one. Return ENOSYS.
 * ------------------------------------------------------------------ */
__attribute__((weak))
int dlinfo(void *handle, int request, void *info)
{
    (void)handle; (void)request; (void)info;
    errno = ENOSYS;
    return -1;
}

/* ------------------------------------------------------------------
 * qsort_r — thread-local trampoline to qsort
 * ------------------------------------------------------------------ */
typedef int (*qsort_r_compar_t)(const void *, const void *, void *);
static __thread qsort_r_compar_t g_qr_compar;
static __thread void            *g_qr_arg;

static int qsort_r_thunk(const void *a, const void *b)
{
    return g_qr_compar(a, b, g_qr_arg);
}

__attribute__((weak))
void qsort_r(void *base, size_t nmemb, size_t size,
             qsort_r_compar_t compar, void *arg)
{
    g_qr_compar = compar;
    g_qr_arg    = arg;
    qsort(base, nmemb, size, qsort_r_thunk);
}

/* ------------------------------------------------------------------
 * glob64 / globfree64 — on musl, off64_t == off_t, just forward.
 * ------------------------------------------------------------------ */
extern int  glob (const char *, int, int (*)(const char *, int), void *);
extern void globfree(void *);

__attribute__((weak))
int glob64(const char *pat, int flags,
           int (*errfunc)(const char *, int), void *pglob)
{
    return glob(pat, flags, errfunc, pglob);
}

__attribute__((weak))
void globfree64(void *pglob) { globfree(pglob); }

/* ------------------------------------------------------------------
 * scandirat / scandirat64
 * ------------------------------------------------------------------ */
__attribute__((weak))
int scandirat(int dirfd, const char *dirp,
              struct dirent ***namelist,
              int (*filter)(const struct dirent *),
              int (*compar)(const struct dirent **,
                            const struct dirent **))
{
    int fd = openat(dirfd, dirp, O_RDONLY | O_DIRECTORY);
    if (fd < 0) return -1;
    DIR *d = fdopendir(fd);
    if (!d) { close(fd); return -1; }

    struct dirent **list = NULL;
    int n = 0, cap = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (filter && !filter(e)) continue;
        struct dirent *copy = (struct dirent *)malloc(sizeof(*e));
        if (!copy) { closedir(d); free(list); return -1; }
        memcpy(copy, e, sizeof(*e));
        if (n == cap) {
            cap = cap ? cap * 2 : 16;
            list = (struct dirent **)realloc(list, cap * sizeof(*list));
        }
        list[n++] = copy;
    }
    closedir(d);
    if (compar) {
        qsort(list, n, sizeof(*list),
              (int (*)(const void *, const void *))compar);
    }
    *namelist = list;
    return n;
}

__attribute__((weak))
int scandirat64(int dirfd, const char *dirp,
                struct dirent ***namelist,
                int (*filter)(const struct dirent *),
                int (*compar)(const struct dirent **,
                              const struct dirent **))
{
    return scandirat(dirfd, dirp, namelist, filter, compar);
}

/* ------------------------------------------------------------------
 * obstack_printf / obstack_vprintf — musl-obstack 不提供
 * ------------------------------------------------------------------ */
struct obstack;
extern void _obstack_grow_box(struct obstack *o, const void *data, size_t n);
/* (real implementation below uses obstack_grow which is a macro; include the
 *  obstack header for it.) */
#include "obstack.h"

__attribute__((weak))
int obstack_vprintf(struct obstack *obs, const char *fmt, va_list ap)
{
    char small[2048];
    va_list ap2;
    va_copy(ap2, ap);
    int n = vsnprintf(small, sizeof(small), fmt, ap);
    if (n >= 0 && (size_t)n < sizeof(small)) {
        obstack_grow(obs, small, n);
    } else if (n >= 0) {
        char *big = (char *)malloc(n + 1);
        if (big) {
            vsnprintf(big, n + 1, fmt, ap2);
            obstack_grow(obs, big, n);
            free(big);
        }
    }
    va_end(ap2);
    return n;
}

__attribute__((weak))
int obstack_printf(struct obstack *obs, const char *fmt, ...)
{
    va_list ap;
    int n;
    va_start(ap, fmt);
    n = obstack_vprintf(obs, fmt, ap);
    va_end(ap);
    return n;
}

/* ------------------------------------------------------------------
 * __ctype_b_loc / __ctype_tolower_loc / __ctype_toupper_loc
 * Allocate 384-entry tables; return pointer offset by +128 so callers
 * can index in [-128, 255] like glibc does.
 * ------------------------------------------------------------------ */
#define BOX_ISupper  0x0100
#define BOX_ISlower  0x0200
#define BOX_ISalpha  0x0400
#define BOX_ISdigit  0x0800
#define BOX_ISxdigit 0x1000
#define BOX_ISspace  0x2000
#define BOX_ISprint  0x4000
#define BOX_ISgraph  0x8000
#define BOX_ISblank  0x0001
#define BOX_IScntrl  0x0002
#define BOX_ISpunct  0x0004
#define BOX_ISalnum  0x0008

static unsigned short box_ctype_b      [384];
static int            box_ctype_tolower[384];
static int            box_ctype_toupper[384];

static const unsigned short *box_ctype_b_ptr       = box_ctype_b       + 128;
static const int            *box_ctype_tolower_ptr = box_ctype_tolower + 128;
static const int            *box_ctype_toupper_ptr = box_ctype_toupper + 128;

__attribute__((constructor(102)))
static void box_init_ctype_tables(void)
{
    for (int c = 0; c < 256; c++) {
        unsigned short f = 0;
        if (c == ' ' || c == '\t')      f |= BOX_ISblank;
        if (c >= 0x09 && c <= 0x0D)     f |= BOX_ISspace;
        if (c == ' ')                   f |= BOX_ISspace;
        if (c < 0x20 || c == 0x7F)      f |= BOX_IScntrl;
        if (c >= 'A' && c <= 'Z')       f |= BOX_ISupper | BOX_ISalpha | BOX_ISalnum | BOX_ISprint | BOX_ISgraph;
        if (c >= 'a' && c <= 'z')       f |= BOX_ISlower | BOX_ISalpha | BOX_ISalnum | BOX_ISprint | BOX_ISgraph;
        if (c >= '0' && c <= '9')       f |= BOX_ISdigit | BOX_ISalnum | BOX_ISxdigit | BOX_ISprint | BOX_ISgraph;
        if ((c >= 'a' && c <= 'f') ||
            (c >= 'A' && c <= 'F'))     f |= BOX_ISxdigit;
        if (c >= 0x21 && c <= 0x7E && !(f & BOX_ISalnum))
            f |= BOX_ISpunct | BOX_ISprint | BOX_ISgraph;
        if (c == ' ')                   f |= BOX_ISprint;

        box_ctype_b      [c + 128] = f;
        box_ctype_tolower[c + 128] = (c >= 'A' && c <= 'Z') ? (c + 32) : c;
        box_ctype_toupper[c + 128] = (c >= 'a' && c <= 'z') ? (c - 32) : c;
    }
}

__attribute__((weak))
const unsigned short **__ctype_b_loc(void)
{
    return (const unsigned short **)&box_ctype_b_ptr;
}

__attribute__((weak))
const int **__ctype_tolower_loc(void)
{
    return (const int **)&box_ctype_tolower_ptr;
}

__attribute__((weak))
const int **__ctype_toupper_loc(void)
{
    return (const int **)&box_ctype_toupper_ptr;
}

/* ------------------------------------------------------------------
 * Misc math helpers some box64 code may reference
 * ------------------------------------------------------------------ */
__attribute__((weak)) int isnanf (float x) { return __builtin_isnan(x); }
__attribute__((weak)) int isinff (float x) { return __builtin_isinf(x); }
__attribute__((weak)) int finitef(float x) { return __builtin_isfinite(x); }

__attribute__((weak)) double      exp10 (double x)      { return pow (10.0,  x); }
__attribute__((weak)) float       exp10f(float x)       { return powf(10.0f, x); }
__attribute__((weak)) long double exp10l(long double x) { return powl(10.0L, x); }
EOF_MUSL_COMPAT
        echo "    [#12]   + $f"
    fi

    if _already "$cm" "$mark"; then
        echo "    [#12]   CMakeLists.txt — already patched"
    else
        echo "    [#12]   append target_sources to CMakeLists.txt"
        cat >> "$cm" << EOF_MUSL_CM

# $mark ====================================
if(TARGET box64)
    target_sources(box64 PRIVATE \${CMAKE_SOURCE_DIR}/src/musl_compat.c)
endif()
# =========================================
EOF_MUSL_CM
    fi
}

# ================================================================
# Patch 13 — src/mallochook.c: 暂时整文件替换为直接 libc 转发
# ================================================================
# 目的:
#   验证 mallochook 是不是启动期 100% CPU 用户态死循环的根源.
#   现象:
#     wchan=0, syscall=none, utime 持续增长, 单线程, 无任何 stderr,
#     十几分钟跑下来仍然如此.  典型的用户态自旋特征.
#   嫌疑:
#     mallochook 在 ctor 阶段会建立 box 内部内存池, 用原子 + spin
#     做并发保护. 如果初始化顺序错位, 第一个调到 box_malloc 的人
#     会在 spin 里等一个永远不会被 set 的 ready flag.
#
# 修法 (诊断用, 暂时性):
#   把整个 mallochook.c 换成 box_* -> libc malloc/free 的直接转发,
#   彻底绕开 box64 自己的内存池. 编译/链接通过, 启动期不再做任何
#   spin. 用这个版本跑 box64 看是否还卡:
#     - 不卡了    -> 锁定 mallochook 是元凶, 后续做正确移植
#     - 仍然卡    -> 不是 mallochook, 下一步去查 DynaRec 池 init /
#                    wrapped 表 init / cpu_info init 等其它 ctor
#
# 风险:
#   box64 翻译 x86 程序时需要 hook guest 的 malloc/free 来管理 guest
#   堆与 host 堆的隔离. 直接转发会丢失这个能力, 不能用于真正运行
#   x86 程序. 这条 patch 仅用于"box64 自身能不能启动"的诊断阶段.
patch_13_disable_mallochook() {
    local f="$BOX64/src/mallochook.c"
    local mark='OHOS_PATCH_DISABLE_MALLOCHOOK'

    [ -f "$f" ] || { _patch_header 13 "(skip) mallochook.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 13 "src/mallochook.c" "mallochook — already replaced"
        return 0
    fi
    _patch_header 13 "src/mallochook.c" "REPLACE with libc passthrough (DIAGNOSTIC)"

cat > "$f" << 'EOF_MH'
/* OHOS_PATCH_DISABLE_MALLOCHOOK -- diagnostic passthrough.
 *
 * 原始 mallochook 用一组 box64 内部内存池 + spin lock 接管所有
 * malloc/free, 怀疑它在 OHOS musl 上的 ctor 阶段死循环.
 *
 * 此版本完全绕开内存池逻辑: 所有 box_* 函数直接转给 libc.
 * 仅用于定位启动期死循环, 不可用于真正翻译 x86 程序.
 */
#include <limits.h>
#include <stdlib.h>
#include <string.h>

extern void *memalign(size_t, size_t);

/* ---------- 基础 box_* 分配族 ---------- */
void *box_malloc(size_t s)                  { return malloc(s); }
void  box_free(void *p)                     { free(p); }
void *box_calloc(size_t n, size_t s)        { return calloc(n, s); }
void *box_realloc(void *p, size_t s)        { return realloc(p, s); }
void *box_memalign(size_t a, size_t s)      { return memalign(a, s); }
char *box_strdup(const char *s)             { return s ? strdup(s) : NULL; }
char *box_strndup(const char *s, size_t n)  { return s ? strndup(s, n) : NULL; }

/* 部分 box64 内部入口的最小桩 */
void   box_free_internal(void *p)              { free(p); }
size_t box_malloc_usable_size(void *p)         { (void)p; return 0; }

/* ---------- box64 启停 hook (诊断版本: 全部空操作) ---------- */
/* 原版会安装/卸载全局 malloc 拦截器, 这里全部 no-op,
 * 让 box64 主流程可以跑下去. */
void init_malloc_hook(void)  {}
void startMallocHook(void)   {}
void endMallocHook(void)     {}

/* checkHookedSymbols: 原版用于扫描刚加载的 ELF 的 dynsym 表,
 * 把命中我们感兴趣的符号 (malloc/free 等) 替换成 box_* 实现.
 * 诊断版本不需要做任何事 -- 我们已经不再 hook 全局 malloc.
 * 第二参数原型一般是 elfheader_t* / SymbolMap*, 用 void* 兼容.
 */
void checkHookedSymbols(void *symbols, void *h)
{
    (void)symbols; (void)h;
}

/* box_realpath: 路径解析 + 失败时退化为原始路径,
 * 保证非 NULL 返回 (box64 多处调用站点不检查 NULL). */
char *box_realpath(const char *path, char *resolved)
{
    if (!path) return NULL;

    char buf[PATH_MAX];
    char *target = resolved ? resolved : buf;
    char *r = realpath(path, target);

    if (r) {
        return resolved ? r : strdup(buf);
    }

    /* realpath 失败 (文件不存在 / 权限 / 等) -- 退化为原始字符串.
     * 不要返回 NULL, box64 上层不做空指针检查. */
    if (resolved) {
        size_t n = strlen(path);
        if (n >= PATH_MAX) n = PATH_MAX - 1;
        memcpy(resolved, path, n);
        resolved[n] = '\0';
        return resolved;
    }
    return strdup(path);
}

/* 不再用强符号覆盖系统 malloc/free, 让 musl 自己处理 */
EOF_MH
}

# ================================================================
# Patch 15 — src/custommem.c: 跳过 glibc 私有的 __curbrk 探测
# ================================================================
# 报错:
#   SIGSEGV @ pc=0  返回地址在 init_custommem_helper (custommem.c:3131)
#   addr2line: main -> initialize -> init_custommem_helper -> [pc 0]
#
# 原因:
#   line 3131 是  cur_brk = dlsym(RTLD_NEXT, "__curbrk");
#   __curbrk 是 glibc 私有的 program-break 跟踪指针, musl 完全没有.
#   而 musl 上从主可执行文件 (非 dlopen 加载的库) 调
#   dlsym(RTLD_NEXT, ...) 行为是 undefined; OHOS musl 表现是
#   走到一条空 PLT, 跳到地址 0 -> SIGSEGV.
#
#   --version 路径在 banner 之后立刻 return, 不会调用
#   init_custommem_helper, 所以那条路过. execve 真实 ELF 走完整
#   初始化流程, 必然命中此处.
#
# 修法:
#   把这行替换成  cur_brk = NULL;
#   musl 没有 brk 跟踪机制, box64 用 cur_brk 的地方 (主要是 sbrk
#   emulation) 在 NULL 时会走 fallback 路径. 静态 x86 程序基本
#   不调 sbrk, 没影响. 后续如果跑到 sbrk-heavy 的程序再做更细的
#   兼容; 现在先让 init_custommem_helper 能跑过去.
patch_15_custommem_no_curbrk() {
    local f="$BOX64/src/custommem.c"
    local mark='OHOS_PATCH_NO_CURBRK'

    [ -f "$f" ] || { _patch_header 15 "(skip) custommem.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 15 "src/custommem.c" "skip __curbrk — already patched"
        return 0
    fi
    _patch_header 15 "src/custommem.c" "drop dlsym(RTLD_NEXT, \"__curbrk\")"

    sed -i 's|cur_brk = dlsym(RTLD_NEXT, "__curbrk");|/* OHOS_PATCH_NO_CURBRK: musl has no __curbrk */ cur_brk = NULL;|' "$f"
}

# ================================================================
# Patch 16 — 全局 RTLD_NEXT -> RTLD_DEFAULT (musl 主程序兼容)
# ================================================================
# 报错:
#   崩在 NewBox64Context 218~225 行附近, 调用了一个 NULL 函数指针.
#
# 原因:
#   musl 上从主可执行文件 (非 LD_PRELOAD 加载的库) 调
#       dlsym(RTLD_NEXT, ...)
#   行为是 undefined: 大多数情况返回 NULL, 个别情况返回一条空 PLT
#   后跳到 0. box64 在多处用 RTLD_NEXT 拿"真"libc 函数:
#     - libtools/libdl.c     real_dlopen / real_dlclose / real_dlsym
#     - os/os_linux.c        libc_mmap64 / libc_munmap
#   这些指针拿到 NULL, 后续被调用就 SIGSEGV 跳到地址 0.
#
# 修法:
#   把所有 RTLD_NEXT 替换成 RTLD_DEFAULT.
#   - RTLD_NEXT  : 在调用方 ELF 之后的库里查找
#   - RTLD_DEFAULT: 全局符号搜索 (默认顺序)
#   box64 使用 RTLD_NEXT 的初衷只是"绕过自己 wrap 的版本拿 libc 原版",
#   而我们的诊断版 mallochook 已经不再 wrap 全局 malloc/free, 所以
#   RTLD_DEFAULT 直接返回 musl 的 libc 实现, 语义等价.
patch_16_rtld_next_to_default() {
    local mark='OHOS_PATCH_RTLD_DEFAULT'

    # 找出所有引用 RTLD_NEXT 的源文件 (排除已打过的)
    local files
    files=$(grep -rl 'RTLD_NEXT' "$BOX64/src" 2>/dev/null)
    if [ -z "$files" ]; then
        _patch_header 16 "(no RTLD_NEXT references)" ""
        return 0
    fi

    local any_done=0
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        if grep -q "$mark" "$f" 2>/dev/null; then
            continue
        fi
        if grep -q '\bRTLD_NEXT\b' "$f"; then
            _patch_header 16 "${f#$BOX64/}" "RTLD_NEXT -> RTLD_DEFAULT"
            sed -i "1i\\
/* $mark */" "$f"
            sed -i 's/\bRTLD_NEXT\b/RTLD_DEFAULT/g' "$f"
            any_done=1
        fi
    done <<< "$files"

    if [ "$any_done" -eq 0 ]; then
        _patch_header 16 "(all RTLD_NEXT files already patched)" ""
    fi
}

# ================================================================
# Patch 17 — src/box64context.c: 跳过 dlopen(NULL, ...) 自引用
# ================================================================
# 报错:
#   崩在 box64context.c:219
#       context->box64lib = dlopen(NULL, RTLD_NOW|RTLD_GLOBAL);
#   反汇编:
#       7b4ce4: bl 0xd89cc8 <dlopen>     ← box64 自己 wrap 的 dlopen
#       内部 PC=0
#
# 原因:
#   box64 在 wrappedlibdl.c 里 EXPORT 了一个名为 'dlopen' 的强符号,
#   用来 wrap libc 的 dlopen. 主程序调 dlopen 时, ld 把它链到 box64
#   自己这版 wrap, wrap 里需要一个 'real_dlopen' 函数指针 (通过
#   dlsym 拿真 libc 实现).
#
#   musl 上从主程序解析 'dlopen' 时, 优先级让它解析回 box64 自己
#   export 的 dlopen, real_dlopen 拿到 NULL 或自身地址 -> NULL 调用.
#
# 修法:
#   box64lib 这个句柄的用途是 dlsym 查 box64 自身 export 的函数.
#   我们诊断阶段不依赖这条路径, 直接设为 NULL. 后续真要用到时,
#   box64 多处会做 NULL guard, 拿不到就走 fallback.
patch_17_skip_box64lib_dlopen() {
    local f="$BOX64/src/box64context.c"
    local mark='OHOS_PATCH_SKIP_BOX64LIB'

    [ -f "$f" ] || { _patch_header 17 "(skip) box64context.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 17 "src/box64context.c" "skip box64lib dlopen — already patched"
        return 0
    fi
    _patch_header 17 "src/box64context.c" "set box64lib = NULL (avoid self-recursive dlopen)"

    sed -i 's#context->box64lib = dlopen(NULL, RTLD_NOW|RTLD_GLOBAL);#/* OHOS_PATCH_SKIP_BOX64LIB */ context->box64lib = NULL;#' "$f"
}

# ================================================================
# Patch 18 — src/libtools/threads.c: 跳过 glibc 私有 pthread 符号 dlsym
# ================================================================
# 报错:
#   崩在 init_pthread_helper @ threads.c:1335
#   反汇编: bl 0xd89fbc <dlsym>
#   原因: box64 EXPORT 了 dlsym 强符号 wrap, 主程序调 dlsym(NULL,...)
#   走到 box64 自己的 wrap, 内部递归找 real_dlsym 时跳到 0.
#
# 即使 dlsym 调用本身没问题, 这几个被查的符号在 musl 上也全部不存在:
#   - _pthread_cleanup_push_defer    glibc 私有
#   - _pthread_cleanup_pop_restore   glibc 私有
#   - pthread_cond_clockwait         glibc 2.30+, musl 接口不同
#   - dlvsym(NULL,"pthread_kill","GLIBC_2.X")  musl 无符号版本化
#
# 修法:
#   直接把这一段 dlsym/dlvsym 查找改成把对应 real_* 指针赋 NULL.
#   box64 在使用 real_pthread_cleanup_*/cond_clockwait/kill_old 之前
#   都有 NULL guard, NULL 时走 fallback (调用普通 pthread_kill 等).
patch_18_skip_pthread_dlsym() {
    local f="$BOX64/src/libtools/threads.c"
    local mark='OHOS_PATCH_SKIP_PTHREAD_DLSYM'

    [ -f "$f" ] || { _patch_header 18 "(skip) threads.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 18 "src/libtools/threads.c" "skip pthread dlsym — already patched"
        return 0
    fi
    _patch_header 18 "src/libtools/threads.c" "replace dlsym(NULL,...) block with NULL assigns"

    # 三行 dlsym 直接 -> NULL
    sed -i \
        -e 's|real_pthread_cleanup_push_defer = (vFppp_t)dlsym(NULL, "_pthread_cleanup_push_defer");|/* OHOS_PATCH_SKIP_PTHREAD_DLSYM */ real_pthread_cleanup_push_defer = NULL;|' \
        -e 's|real_pthread_cleanup_pop_restore = (vFpi_t)dlsym(NULL, "_pthread_cleanup_pop_restore");|/* OHOS_PATCH_SKIP_PTHREAD_DLSYM */ real_pthread_cleanup_pop_restore = NULL;|' \
        -e 's|real_pthread_cond_clockwait = (iFppip_t)dlsym(NULL, "pthread_cond_clockwait");|/* OHOS_PATCH_SKIP_PTHREAD_DLSYM */ real_pthread_cond_clockwait = NULL;|' \
        "$f"

    # 那段 for 循环 + dlvsym 找老版本 pthread_kill: 直接跳过整个查找,
    # 让代码走 "if (!real_phtread_kill_old) ... = pthread_kill" 兜底分支
    # 用 awk 把从 'search for older symbol' 到 '"GLIBC_2.2.5");' 之间整段注释掉
    awk '
        BEGIN { skip = 0 }
        /search for older symbol for pthread_kill/ { skip = 1 }
        skip {
            print "/* " $0 " */"
            if (/"GLIBC_2\.2\.5"\);/) skip = 0
            next
        }
        { print }
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# ================================================================
# Patch 19 v3 — wrappedlibc.c: 禁用 PRE_INIT 里的 dlopen(NULL,...)
# ================================================================
# 现象:
#   wrappedlibc_init 的 PRE_INIT 宏展开成
#       lib->w.lib = dlopen(NULL, RTLD_LAZY|RTLD_GLOBAL);
#   这个调用进入 box64 自己 export 的 dlopen trampoline,
#   trampoline 在 musl 环境下 cache 写不上, br 0 → SIGSEGV.
#
# 修法:
#   把 PRE_INIT 改成空宏. 这一步原本是想拿主程序的句柄做 fallback
#   符号查找; musl 上 dlopen(NULL,...) 语义不同, 后续 wrappedlib_init
#   走 dlopen(libcName,...) 也能让 lib->w.lib 拿到非 NULL handle.
#
# 注意:
#   即使改空, dlopen("libc.so",...) 那一行仍然会进 trampoline,
#   后续可能在 my_dlopen 递归加载 libc 处再爆.  这条 patch 只是把
#   死亡点从 PRE_INIT 推到下一关, 方便观察新栈.
patch_19_no_pre_init_dlopen() {
    local f="$BOX64/src/wrapped/wrappedlibc.c"
    local mark='OHOS_PATCH_NO_PRE_INIT_DLOPEN'
    [ -f "$f" ] || return 0
    if _already "$f" "$mark"; then
        _patch_header 19 "src/wrapped/wrappedlibc.c" "PRE_INIT noop — already"
        return 0
    fi
    _patch_header 19 "src/wrapped/wrappedlibc.c" "neutralize PRE_INIT dlopen(NULL,...)"

    python3 - "$f" "$mark" << 'PY'
import sys, re
p, mark = sys.argv[1], sys.argv[2]
s = open(p).read()

# 匹配整个 #ifndef STATICBUILD ... #endif 包住的 PRE_INIT 定义块,
# 替换成"PRE_INIT 定义为空"——模板里 PRE_INIT 后紧跟 '{',
# 空展开后那个 '{' 就是普通块开始, 编译合法.
pat = re.compile(
    r"#ifndef\s+STATICBUILD\s*\n"
    r"#define\s+PRE_INIT.*?dlopen\s*\(\s*NULL[^;]*;\s*\\\s*\n"
    r"\s*else\s*\n"
    r"#endif",
    re.S)

repl = ("/* %s */\n"
        "/* PRE_INIT was: dlopen(NULL,...) -- disabled on OHOS musl, */\n"
        "/* see patch 19 notes. Empty macro is fine because the */\n"
        "/* template uses bare 'PRE_INIT' with no trailing ';' and the */\n"
        "/* following '{' becomes a plain compound statement.        */\n"
        "#define PRE_INIT" % mark)

if not pat.search(s):
    print("WARN: PRE_INIT block not found", file=sys.stderr); sys.exit(0)
s = pat.sub(repl, s, count=1)
open(p, 'w').write(s)
print("OK")
PY
}

# ================================================================
# Patch 20 — src/libtools/libdl.c: 降级 EXPORT 为 static
# ================================================================
# 现象:
#   libtools/libdl.c 里 EXPORT 出来的 dlopen / dlsym / dlclose / ...
#   是一组转发 shim, 内部缓存 'real_dlopen' 等函数指针, 用
#   GetNativeSymbolUnversioned(RTLD_DEFAULT,"dlopen") 取真 libc 实现.
#   OHOS musl 上这条路返回 0, cache 写 0, br x2 → SIGSEGV @0.
#
#   只要 box64 host 代码里有任何一处调 dlopen() / dlsym() / ...,
#   就会被 linker 解析到这组 shim, 就会爆.  PRE_INIT 改空之后,
#   wrappedlib_init.h:176 的 dlopen("libc.so",...) 又中招.
#
# 修法:
#   把 libdl.c 顶部的 EXPORT 宏覆盖成 'static __attribute__((unused))'.
#   原本是全局强符号的几个 dl* 函数变成本 .o 私有, 其它 .o 看不到,
#   linker 在解析 host 代码里的 dlopen()/dlsym()/... 时找不到本模块
#   定义, 直接通过 PLT 解析到 musl libc 真版本.
#
# 影响:
#   - host 代码 dlopen()/dlsym()/dlclose() 调用 → musl libc 真实现 ✓
#   - guest x86 程序的 dlopen 走 wrappedlibdl.c::my_dlopen, 不依赖
#     这组 trampoline, 完全不受影响 ✓
#   - box64 二进制的动态导出表里不再有 'dlopen' 等同名强符号,
#     如果设备上有别的 .so 通过 dlsym(box64_handle,"dlopen") 找符号
#     会失败 — 但实际场景没人这么做.
patch_20_libdl_rename_shims() {
    local f="$BOX64/src/libtools/libdl.c"
    local mark='OHOS_PATCH_LIBDL_RENAME_SHIMS'
    [ -f "$f" ] || return 0
    if _already "$f" "$mark"; then
        _patch_header 20 "src/libtools/libdl.c" "rename dl* shims — already"
        return 0
    fi
    _patch_header 20 "src/libtools/libdl.c" "rename dl* shims to _unused (host -> musl PLT)"

    sed -i "1i\\
/* $mark */" "$f"

    # 关键: 直接把函数名改掉, 让 box64 binary 不再定义这几个全局符号.
    # host 代码里所有 dlopen/dlsym/dlclose 调用因为本 binary 找不到
    # 定义, linker 会通过 PLT 解析到 musl libc 真 dlopen.
    #
    # 这几个 shim 本身是死代码 (没人会再调用它们), 加 unused 属性避免
    # clang 报 unused-function 警告 (我们已经全局 -Wno-unused-function,
    # 但保留属性方便 grep).
    sed -i \
        -e 's|^EXPORT void\* dlopen(|__attribute__((unused)) static void* box64_unused_dlopen(|' \
        -e 's|^EXPORT int dlclose(|__attribute__((unused)) static int box64_unused_dlclose(|' \
        -e 's|^EXPORT void\* dlsym(|__attribute__((unused)) static void* box64_unused_dlsym(|' \
        -e '/^EXPORT void\* ___dlsym.*alias.*dlsym.*;/d' \
        "$f"

    # 同步把它们内部的递归引用 (有的话) 也改掉; 简单起见直接全删 alias 行.
    # 实际 libdl.c 里这三个函数互不调用, 改完即可.
}

# ================================================================
# Patch 21 — src/include/myalign32.h: BOX32 用到的 glibc 私有 typedef
# ================================================================
# 报错(节选, 在所有 include 了 myalign32.h 的 *32* 文件里都会出现):
#   error: unknown type name '__uid_t'; did you mean 'uid_t'?
#       __uid_t pw_uid;
#   error: unknown type name '__gid_t'; did you mean 'gid_t'?
#       __gid_t pw_gid;
#       __gid_t gr_gid;
#   error: unknown type name '__fsblkcnt64_t'   (in myalign64_32.c)
#   error: unknown type name '__fsfilcnt64_t'   (in myalign64_32.c)
#
# 原因:
#   __uid_t / __gid_t / __pid_t / __fsblkcnt64_t / __fsfilcnt64_t 是
#   glibc 内部 typedef, 暴露在 <bits/types.h>. musl 没有这层抽象,
#   只有 POSIX 规定的无前导下划线版本 (uid_t / gid_t / pid_t / 等).
#
# 修法:
#   在 myalign32.h 最顶部加一组 fallback typedef. 因为我们用 sed 1i
#   插入到包含 guard 之外, 用自己的 BOX64_OHOS_GLIBC_TYPES_GUARD 防
#   多次 include 时重复 typedef.
#
#   myalign32.h 被以下文件 include, 一处定义全局生效:
#     myalign32.c, myalignxcb32.c, myalign64_32.c, sdl1align32.c,
#     sdl2align32.c, libc_net32.c, my_x11_conv.c, ...
patch_21_myalign32_glibc_types() {
    local f="$BOX64/src/include/myalign32.h"
    local mark='OHOS_PATCH_MYALIGN32_GLIBC_TYPES'

    [ -f "$f" ] || { _patch_header 21 "(skip) myalign32.h not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 21 "src/include/myalign32.h" "glibc typedefs — already patched"
        return 0
    fi
    _patch_header 21 "src/include/myalign32.h" "add __uid_t/__gid_t/__pid_t/__fs*64_t typedefs"

    sed -i "1i\\
/* $mark */\\
#ifndef BOX64_OHOS_GLIBC_TYPES_GUARD\\
#define BOX64_OHOS_GLIBC_TYPES_GUARD 1\\
#include <sys/types.h>\\
#include <sys/statvfs.h>\\
typedef uid_t       __uid_t;\\
typedef gid_t       __gid_t;\\
typedef pid_t       __pid_t;\\
typedef fsblkcnt_t  __fsblkcnt64_t;\\
typedef fsfilcnt_t  __fsfilcnt64_t;\\
#endif" "$f"
}

# ================================================================
# Patch 22 — src/libtools/signal32.c: glibc siginfo_t / __pid_t 兼容
# ================================================================
# 报错(本文件直接出现, 不是 include 链):
#   error: unknown type name '__pid_t'   (288/297/302)
#   error: unknown type name '__uid_t'   (289/298/303)
#   error: unknown type name '__SI_SIGFAULT_ADDL'   (310)
#   error: no member named '_sifields' in 'siginfo_t'   (469)
#
# 原因:
#   1. signal32.c 顶部不 include myalign32.h, patch 21 的 typedef
#      传不进来; 自己再加一份.
#   2. __SI_SIGFAULT_ADDL 是 glibc bits/types/siginfo_t.h 里的"扩展
#      字段宏", 在 BOX32 仿造的 32-bit siginfo_t 结构体里被嵌入. musl
#      没有这个宏. 定义为空即可 (该路径 signal info 不需要 SIGFAULT
#      addl 那两个 _addr_bnd_* 字段).
#   3. musl 的 siginfo_t 把"区分各个 si_code 的联合"叫 __si_fields,
#      glibc 叫 _sifields. memcpy(&dst->_sifields, ...) 这样的代码
#      在 musl 上找不到字段. 用 #define _sifields __si_fields 把所有
#      该名字替换掉, 包括 offsetof() 里的引用.
patch_22_signal32_glibc_compat() {
    local f="$BOX64/src/libtools/signal32.c"
    local mark='OHOS_PATCH_SIGNAL32_GLIBC'

    [ -f "$f" ] || { _patch_header 22 "(skip) signal32.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 22 "src/libtools/signal32.c" "glibc compat — already patched"
        return 0
    fi
    _patch_header 22 "src/libtools/signal32.c" "typedefs + __SI_SIGFAULT_ADDL + _sifields rename"

    sed -i "1i\\
/* $mark */\\
#ifndef BOX64_OHOS_SIGNAL32_GUARD\\
#define BOX64_OHOS_SIGNAL32_GUARD 1\\
#include <sys/types.h>\\
#include <signal.h>\\
typedef pid_t __pid_t;\\
typedef uid_t __uid_t;\\
typedef gid_t __gid_t;\\
#ifndef __SI_SIGFAULT_ADDL\\
#define __SI_SIGFAULT_ADDL  /* glibc-only extension fields, drop on musl */\\
#endif\\
/* musl: siginfo_t::_sifields  ->  __si_fields */\\
#define _sifields __si_fields\\
#endif" "$f"
}

# ================================================================
# Patch 23 — src/libtools/libc_net32.c: 跳过 glibc 私有 res_state 字段
# ================================================================
# 报错:
#   error: no member named '__glibc_unused_qhook' in 'struct __res_state'
#   error: no member named '__glibc_unused_rhook' in 'struct __res_state'
#       (出现在 4 处赋值: 573/574/593/594)
#
# 原因:
#   struct __res_state (resolver state) 在 glibc 末尾保留了两个废弃
#   的回调指针 __glibc_unused_qhook / __glibc_unused_rhook (历史遗留,
#   早就不再使用). musl 的 resolv.h 没有这两个字段.
#
#   box64 的 libc_net32.c 在做 32<->64 res_state 结构搬运时无条件
#   赋值, 编不过.
#
# 修法:
#   把 4 行赋值整体注释掉. 这两个字段就算赋了, glibc 后续也不会读;
#   musl 上根本没有, 跳过 0 影响.
patch_23_libc_net32_skip_glibc_hooks() {
    local f="$BOX64/src/libtools/libc_net32.c"
    local mark='OHOS_PATCH_LIBC_NET32_HOOKS'

    [ -f "$f" ] || { _patch_header 23 "(skip) libc_net32.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 23 "src/libtools/libc_net32.c" "glibc res hooks — already patched"
        return 0
    fi
    _patch_header 23 "src/libtools/libc_net32.c" "comment out __glibc_unused_*hook accesses"

    sed -i "1i\\
/* $mark */" "$f"

    # 用 sed 把 4 行 (qhook/rhook 各两次) 替换成纯注释
    sed -i \
        -e 's|^\(\s*\)dst->__glibc_unused_qhook = to_ptrv(src->__glibc_unused_qhook);|\1/* OHOS musl: __res_state has no __glibc_unused_qhook */|' \
        -e 's|^\(\s*\)dst->__glibc_unused_rhook = to_ptrv(src->__glibc_unused_rhook);|\1/* OHOS musl: __res_state has no __glibc_unused_rhook */|' \
        -e 's|^\(\s*\)dst->__glibc_unused_rhook = from_ptrv(src->__glibc_unused_rhook);|\1/* OHOS musl: __res_state has no __glibc_unused_rhook */|' \
        -e 's|^\(\s*\)dst->__glibc_unused_qhook = from_ptrv(src->__glibc_unused_qhook);|\1/* OHOS musl: __res_state has no __glibc_unused_qhook */|' \
        "$f"
}

# ================================================================
# Patch 24 — src/libtools/threads32.c: cleanup decls + __pthread_mutex_s
# ================================================================
# 报错:
#   error: conflicting types for '_pthread_cleanup_push'   (53)
#   error: conflicting types for '_pthread_cleanup_pop'    (54)
#   error: incomplete definition of type 'struct __pthread_mutex_s'
#       fake->i386__kind = ((struct __pthread_mutex_s*)from_ptrv(...))->__kind;
#                                                                    (1015)
#
# 原因:
#   1. 跟 patch_05 在 threads.c 里处理过的同一类问题: box64 自己声明了
#      内部 NPTL 函数 _pthread_cleanup_push/_pthread_cleanup_pop, 而
#      musl 在公共 <pthread.h> 里也声明了同名函数, 但参数类型不同.
#      threads32.c 是 BOX32 的 32-bit guest 版本, 撞同样的坑.
#   2. struct __pthread_mutex_s 是 glibc 内部布局, musl 不暴露这个
#      tag. box64 想读 glibc mutex 的 __kind 字段 (区分普通/递归/
#      错误检查), 在 musl 上字段位置完全不同, 不可能读到正确值.
#
# 修法:
#   1. 删 box64 自己写的 _pthread_cleanup_push/pop 前向声明, 让 musl
#      的版本生效 (patch_05 的同一手法).
#   2. 把 ((struct __pthread_mutex_s*)...)->__kind 整个表达式替换成
#      常量 0 (= PTHREAD_MUTEX_NORMAL). 后续 box64 用 i386__kind 决定
#      重入/错误检查, 当 0 处理就是普通互斥锁, 大多数 32-bit guest
#      程序都用普通锁, 行为一致.
patch_24_threads32_pthread() {
    local f="$BOX64/src/libtools/threads32.c"
    local mark='OHOS_PATCH_THREADS32_PTHREAD'

    [ -f "$f" ] || { _patch_header 24 "(skip) threads32.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 24 "src/libtools/threads32.c" "pthread compat — already patched"
        return 0
    fi
    _patch_header 24 "src/libtools/threads32.c" "drop cleanup_push/pop decls + stub __pthread_mutex_s"

    sed -i "1i\\
/* $mark */" "$f"

    # 同 patch_05: 删 box64 自己写的内部 cleanup_push/pop 前向声明
    sed -i \
        -e '/^[[:space:]]*void[[:space:]]\+_pthread_cleanup_push[[:space:]]*(.*);/d' \
        -e '/^[[:space:]]*void[[:space:]]\+_pthread_cleanup_pop[[:space:]]*(.*);/d' \
        "$f"

    # __pthread_mutex_s.__kind 读取 -> 常量 0 (PTHREAD_MUTEX_NORMAL)
    sed -i 's|((struct __pthread_mutex_s\*)from_ptrv(fake->real_mutex))->__kind|0 /* OHOS musl: no struct __pthread_mutex_s.__kind */|g' "$f"
}

# ================================================================
# Patch 25 — src/libtools/myalign32.c: musl-obstack 字段 layout 不同
# ================================================================
# 报错:
#   error: no member named 'tempptr' in 'union obstack::(unnamed at .../obstack.h:170:3)'
#       dst->temp.tempptr = to_ptrv(src->temp.tempptr);
#   error: passing 'union (unnamed union at .../obstack.h:178:3)' to parameter
#          of incompatible type 'void *'
#       dst->chunkfun = to_ptrv(src->chunkfun);
#   error: passing 'union (unnamed union at .../obstack.h:183:3)' to parameter
#          of incompatible type 'void *'
#       dst->freefun = to_ptrv(src->freefun);
#       (以及 from_ptrv 反向 3 处, 共 6 行)
#
# 原因:
#   box64 的 myalign32.c 里有一段 obstack 32<->64 结构搬运, 直接读
#   src->chunkfun / src->freefun / src->temp.tempptr 这些字段, 假设
#   它们都是单一指针. 但我们用的 musl-obstack (void-linux/musl-obstack)
#   把 chunkfun / freefun 做成了匿名 union (区分 plain / extra 两种
#   签名), 而 temp 也是匿名 union, 字段名不是 tempptr.
#
#   于是:
#     - obstack.h 里的 temp 联合在该版本里没有 tempptr 这个成员名
#     - chunkfun/freefun 是 union, 不能直接作为 void* 参数传
#
# 修法:
#   注释掉这 6 行 obstack 字段搬运. 影响范围:
#     - guest x86 程序如果通过 box64 syscall 边界传递 obstack 指针
#       (gcc / glibc 内部偶尔这样), 会丢失内部状态; 但 obstack 本身
#       几乎不跨进程边界, 实际场景命中概率极低.
#     - 大多数普通程序根本不接触 obstack, 这条 patch 0 影响.
#
#   后续如果要做完整支持, 应该按 musl-obstack 的实际 union 形式访问
#   (e.g.  src->chunkfun.plain  或  src->chunkfun.extra), 不在 clean
#   bring-up 阶段做.
patch_25_myalign32_obstack_skip() {
    local f="$BOX64/src/libtools/myalign32.c"
    local mark='OHOS_PATCH_MYALIGN32_OBSTACK_SKIP'

    [ -f "$f" ] || { _patch_header 25 "(skip) myalign32.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 25 "src/libtools/myalign32.c" "obstack skip — already patched"
        return 0
    fi
    _patch_header 25 "src/libtools/myalign32.c" "stub obstack 32<->64 field copy (musl-obstack layout)"

    sed -i "1i\\
/* $mark */" "$f"

    # 6 行精确替换为注释 (注意句尾分号要带上, 避免破坏块结构)
    sed -i \
        -e 's|dst->temp\.tempptr = to_ptrv(src->temp\.tempptr);|/* OHOS musl-obstack: temp layout differs */ (void)0;|' \
        -e 's|dst->chunkfun = to_ptrv(src->chunkfun);|/* OHOS musl-obstack: chunkfun is anon union */ (void)0;|' \
        -e 's|dst->freefun = to_ptrv(src->freefun);|/* OHOS musl-obstack: freefun is anon union */ (void)0;|' \
        -e 's|dst->freefun = from_ptrv(src->freefun);|/* OHOS musl-obstack: freefun is anon union */ (void)0;|' \
        -e 's|dst->chunkfun = from_ptrv(src->chunkfun);|/* OHOS musl-obstack: chunkfun is anon union */ (void)0;|' \
        -e 's|dst->temp\.tempptr = from_ptrv(src->temp\.tempptr);|/* OHOS musl-obstack: temp layout differs */ (void)0;|' \
        "$f"
}

# ================================================================
# Patch 26 — src/wrapped32/wrappedlibc.c: BOX32 版 musl 兼容大补
# ================================================================
# 报错(节选):
#   error: duplicate member 'fstatvfs' / 'statvfs' / 'fstatat'
#       (musl: #define fstatvfs64 fstatvfs / #define statvfs64 statvfs /
#               #define fstatat64 fstatat 把 wrapper 表撞同名)
#   error: use of undeclared identifier '__compar_d_fn_t'
#   error: indirection requires pointer operand ('int' invalid)
#       (memcpy(..., &((*__ctype_b_loc())[-128]), ...))
#   error: no member named 'gl_flags' in 'glob_t'
#   error: use of undeclared identifier 'GLOB_ALTDIRFUNC'
#   error: no member named '__allocated' / '__used' in
#          'posix_spawn_file_actions_t'
#   error: use of undeclared identifier '__NFDBITS'
#
# 这个文件是 BOX32 的 32-bit guest libc wrapper, 跟 patch 09/10
# 在 64-bit wrappedlibc.c 上做的事几乎对称, 加上 BOX32 独有的几个
# 32<->64 struct 搬运字段问题. 一份 patch 处理 7 类报错:
#
#   A) 顶部 prologue:
#      - _GNU_SOURCE / sched.h / select.h / pthread.h / ctype.h
#      - PTHREAD_RECURSIVE/ERRORCHECK_MUTEX_INITIALIZER_NP fallback
#      - __compar_d_fn_t typedef
#      - __ctype_*_loc 函数声明
#      - GLOB_ALTDIRFUNC 数值 fallback (用 glibc 的 (1<<9))
#      - __NFDBITS = 8*sizeof(long) (host 视角, 等同 glibc 64-bit)
#
#   B) #include "wrappercallback32.h" 之前 #undef *64 宏:
#      stat64/fstat64/lstat64/fstatat64/fopen64/ftw64/nftw64/
#      scandir64/open64/mmap64/statvfs64/fstatvfs64
#      让 wrapper 表里 GO(stat64,...) 和 GO(stat,...) 解析成不同符号
#
#   C) #include 之后 #define *64 = 不带 64 版本:
#      让本文件后续直接调 stat64()/fopen64()/...等仍能编译
#      (musl 上 *64 函数与不带 64 的等价)
#
#   D) glob_t.gl_flags 访问 -> no-op (musl 没此字段, 仅丢失 flags 副本,
#      实际 glob 行为由调用 glob() 时的 flags 参数决定, 不影响功能)
#
#   E) posix_spawn_file_actions_t.__allocated/__used -> no-op
#      (glibc 私有, 用于跟踪 actions 数组容量; musl 内部布局不同,
#       这两个字段对 guest 行为无外部可观察影响)
patch_26_wrappedlibc32() {
    local f="$BOX64/src/wrapped32/wrappedlibc.c"
    local mark='OHOS_PATCH_WRAPPEDLIBC32'

    [ -f "$f" ] || { _patch_header 26 "(skip) wrapped32/wrappedlibc.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 26 "src/wrapped32/wrappedlibc.c" "musl compat — already patched"
        return 0
    fi
    _patch_header 26 "src/wrapped32/wrappedlibc.c" "BOX32 wrappedlibc musl compat (mirror of 09/10 + extras)"

    # ---- A) 顶部 prologue ----
    sed -i "1i\\
/* $mark */\\
#ifndef _GNU_SOURCE\\
#define _GNU_SOURCE\\
#endif\\
#include <ctype.h>\\
#include <pthread.h>\\
#include <sched.h>\\
#include <sys/select.h>\\
#ifndef PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP\\
#define PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP PTHREAD_MUTEX_INITIALIZER\\
#endif\\
#ifndef PTHREAD_ERRORCHECK_MUTEX_INITIALIZER_NP\\
#define PTHREAD_ERRORCHECK_MUTEX_INITIALIZER_NP PTHREAD_MUTEX_INITIALIZER\\
#endif\\
typedef int (*__compar_d_fn_t)(const void *, const void *, void *);\\
extern const unsigned short **__ctype_b_loc(void);\\
extern const int **__ctype_tolower_loc(void);\\
extern const int **__ctype_toupper_loc(void);\\
/* glibc-only GLOB_ALTDIRFUNC: keep value, never honored on musl */\\
#ifndef GLOB_ALTDIRFUNC\\
#define GLOB_ALTDIRFUNC (1 << 9)\\
#endif\\
/* glibc-private __NFDBITS */\\
#ifndef __NFDBITS\\
#define __NFDBITS (8 * (int)sizeof(long))\\
#endif\\
/* $mark END */" "$f"

    # ---- B) #include "wrappercallback32.h" 之前 undef *64 宏 ----
    sed -i '/^#include "wrappercallback32.h"/i\
/* OHOS_UNDEF_BEFORE_CB32 */\
#undef stat64\
#undef fstat64\
#undef lstat64\
#undef fstatat64\
#undef fopen64\
#undef ftw64\
#undef nftw64\
#undef scandir64\
#undef open64\
#undef mmap64\
#undef statvfs64\
#undef fstatvfs64\
/* OHOS_UNDEF_BEFORE_CB32 END */' "$f"

    # ---- C) #include 之后 redefine *64 ----
    sed -i '/^#include "wrappercallback32.h"/a\
/* OHOS_REDEF_AFTER_CB32 */\
#define stat64     stat\
#define fstat64    fstat\
#define lstat64    lstat\
#define fstatat64  fstatat\
#define fopen64    fopen\
#define ftw64      ftw\
#define nftw64     nftw\
#define scandir64  scandir\
#define open64     open\
#define mmap64     mmap\
#define statvfs64  statvfs\
#define fstatvfs64 fstatvfs\
/* OHOS_REDEF_AFTER_CB32 END */' "$f"

    # ---- D) glob_t.gl_flags 访问: musl 没此字段, 改 no-op ----
    sed -i 's|dst->gl_flags = src->gl_flags;|/* OHOS musl glob_t: no gl_flags */ (void)0;|g' "$f"

    # ---- E) posix_spawn_file_actions_t 私有字段: 改 no-op ----
    sed -i \
        -e 's|dst->__allocated = src->__allocated;|/* OHOS musl posix_spawn_file_actions_t: no __allocated */ (void)0;|g' \
        -e 's|dst->__used = src->__used;|/* OHOS musl posix_spawn_file_actions_t: no __used */ (void)0;|g' \
        "$f"
}

# ================================================================
# Patch 27 — link stubs: box32_* allocators + glibc-only libc fns
# ================================================================
# 报错(节选, 链接阶段):
#   ld.lld: error: undefined symbol: box32_free
#   ld.lld: error: undefined symbol: box32_calloc
#   ld.lld: error: undefined symbol: box32_malloc
#   ld.lld: error: undefined symbol: box32_realloc
#   ld.lld: error: undefined symbol: box32_strdup
#   ld.lld: error: undefined symbol: getprotobyname_r
#   ld.lld: error: undefined symbol: getprotobynumber_r
#   ld.lld: error: undefined symbol: __res_state
#   ld.lld: error: undefined symbol: __chk_fail
#   ld.lld: error: undefined symbol: getcontext / makecontext / swapcontext
#
# 原因:
#   box32_*: 上游定义在 mallochook.c, 而 patch_13 把 mallochook.c 整
#            体换成了 libc passthrough 诊断版, 没保留 box32_* 那一组.
#            BOX32 开启后到处引用, 链接失败.
#   getprotoby*_r: glibc GNU 扩展, musl 只有非 _r 版.
#   __res_state:   glibc 的 resolver TLS getter, musl 没有.
#   __chk_fail:    glibc FORTIFY 运行时 helper.
#   *context():    OHOS musl 这版没编 ucontext 实现 (wrappedexpat 的
#                  XML 协程路径引用到, 大多数 guest 程序不会触发).
#
# 修法:
#   新建 src/musl_box32_stubs.c, 集中提供链接所需符号的 stub 实现,
#   并 append 到 CMakeLists.txt 的 box64 target_sources.
#
# 重要 caveat — 仅 bring-up 可用, 生产仍需修:
#   * box32_* 这一组在上游本意是从 <4GB 可达池里分配, 让 32-bit guest
#     指针 (经过 to_ptrv 截断) 仍指向真实有效的 host 内存. 这里我们
#     直接 passthrough 给 libc malloc, host 上分配的指针可能 >4GB,
#     to_ptrv 截断后 guest 拿到的就是无效地址 -> 跑 i386 ELF 时大概
#     率在第一次堆访问就 SIGSEGV. 链接没问题, 跑起来要看运气. 真要
#     稳定运行得做一个 MAP_32BIT 风格的 mmap pool (musl arm64 没有
#     MAP_32BIT, 得自己用 mmap hint + 失败重试圈一块 <4GB 区域).
#   * getprotoby*_r: 用非 _r 版包一层, 不是真正可重入, 但够用.
#   * getcontext/makecontext/swapcontext: 调到就报错退出, 触发的
#     guest 路径基本就是 expat 的协程式 ParseBuffer, 普通 XML 解析
#     不走这条.
patch_27_box32_link_stubs() {
    local f="$BOX64/src/musl_box32_stubs.c"
    local mark='OHOS_PATCH_BOX32_LINK_STUBS'
    local cml="$BOX64/CMakeLists.txt"

    if [ -f "$f" ] && _already "$f" "$mark"; then
        _patch_header 27 "src/musl_box32_stubs.c" "BOX32 link stubs — already patched"
        return 0
    fi
    _patch_header 27 "src/musl_box32_stubs.c" "create BOX32 link stubs file"

    cat > "$f" << 'EOF_STUBS'
/* OHOS_PATCH_BOX32_LINK_STUBS
 *
 * Link-time stubs for the BOX32 build on HarmonyOS musl.
 *
 * 两组:
 *
 * 1) box32_malloc/calloc/realloc/free/strdup
 *    上游放在 mallochook.c. 因为 patch_13 把 mallochook.c 替换成
 *    诊断 passthrough 版了, 这里补回 BOX32 用到的几个.
 *
 *    WARNING: 真正的 BOX32 期望这组分配器从 <4GB 可达池里返回内存,
 *    保证 32-bit guest 指针 (to_ptrv 截断后) 仍指向真实 host 内存.
 *    这里直接走 libc malloc, host 指针可能 >4GB, 跑 i386 ELF 时
 *    guest 访问会 SIGSEGV. 链接 OK, 运行未必 OK, 后续需要做低 4GB
 *    mmap pool 才能稳定运行.
 *
 * 2) OHOS musl 不提供的 libc 函数:
 *      getprotobyname_r / getprotobynumber_r  -- glibc GNU 扩展
 *      __res_state                            -- glibc resolver TLS getter
 *      __chk_fail                             -- glibc FORTIFY abort helper
 *      getcontext / makecontext / swapcontext -- 这版 OHOS musl 没编
 */

#define _GNU_SOURCE
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <netdb.h>
#include <errno.h>
#include <resolv.h>
#include <ucontext.h>

/* ---- 1) box32_* allocators -- NOT here, see patch 28 ----------- *
 *
 * box32_malloc / calloc / realloc / free / strdup / memalign /
 * malloc_usable_size 都由 patch 28 在 src/musl_compat.c 里实现
 * (低 4GB heap allocator). 这里如果再定义一份, 会和 patch 28 强
 * 符号冲突, ld.lld 报 duplicate symbol.
 */

/* ---- 2) glibc-only libc functions ------------------------------ */

/* getprotoby*_r: emulate via non-_r variants. 真正的可重入语义没法
 * 用纯 musl 实现, 这里只满足链接和大多数单线程调用. */
int getprotobyname_r(const char* name,
                     struct protoent* result_buf,
                     char* buf, size_t buflen,
                     struct protoent** result)
{
    (void)result_buf; (void)buf; (void)buflen;
    struct protoent* p = getprotobyname(name);
    if (!p) { *result = NULL; return ENOENT; }
    *result = p;   /* points to libc-internal static; not thread-safe */
    return 0;
}

int getprotobynumber_r(int proto,
                       struct protoent* result_buf,
                       char* buf, size_t buflen,
                       struct protoent** result)
{
    (void)result_buf; (void)buf; (void)buflen;
    struct protoent* p = getprotobynumber(proto);
    if (!p) { *result = NULL; return ENOENT; }
    *result = p;
    return 0;
}

/* __res_state: glibc 返回 TLS resolver state. 这里给一个静态 buffer,
 * 不依赖 musl 的 _res 是否实际链接得到 (有些 musl 配置里 _res 也
 * 可能解析不出). 大多数 box64 调用方只是读取指针, 不真正用里面
 * 的字段. */
struct __res_state* __res_state(void)
{
    static struct __res_state ohos_res_state;  /* zero-initialized */
    return &ohos_res_state;
}

/* __chk_fail: FORTIFY 抛弃路径, 直接 abort. */
__attribute__((noreturn))
void __chk_fail(void)
{
    fprintf(stderr, "*** buffer overflow detected (__chk_fail stub) ***\n");
    abort();
}

/* ucontext: 这版 OHOS musl 没编. 调到就退出, 路径稀少 (基本只有
 * wrappedexpat 的协程式 XML_ParseBuffer 才走). */
int getcontext(ucontext_t* ucp)
{
    (void)ucp;
    fprintf(stderr, "BOX64/OHOS: getcontext() not supported on this musl\n");
    errno = ENOSYS;
    return -1;
}

void makecontext(ucontext_t* ucp, void (*func)(void), int argc, ...)
{
    (void)ucp; (void)func; (void)argc;
    fprintf(stderr, "BOX64/OHOS: makecontext() not supported on this musl\n");
}

int swapcontext(ucontext_t* oucp, const ucontext_t* ucp)
{
    (void)oucp; (void)ucp;
    fprintf(stderr, "BOX64/OHOS: swapcontext() not supported on this musl\n");
    errno = ENOSYS;
    return -1;
}
EOF_STUBS

    echo "[#27]   + $f"

    # 注册到 CMakeLists.txt 的 box64 target
    if ! grep -q "$mark" "$cml"; then
        cat >> "$cml" << EOF_CML

# $mark
target_sources(box64 PRIVATE \${CMAKE_CURRENT_SOURCE_DIR}/src/musl_box32_stubs.c)
EOF_CML
        echo "[#27]   append target_sources to CMakeLists.txt"
    fi
}

# ================================================================
# Patch 28 — src/musl_compat.c: BOX32 完整 allocator 套件
# ================================================================
# 关键发现:
#   debug.h 里有
#     #define actual_malloc(A) (box64_is32bits?box32_malloc(A):box_malloc(A))
#     #define actual_free(A)   (box64_is32bits?box32_free(A):box_free(A))
#   等一组宏. box64 源码里所有可能落到 guest 的分配点都用 actual_*,
#   编译期就会被路由到 box32_*. 所以我们只需要 box32_* 自己实现对,
#   完全不用动 box_malloc.
#   debug.h 引用的 box32_* 全集 (7 个):
#     box32_malloc / box32_calloc / box32_realloc / box32_free
#     box32_memalign / box32_strdup / box32_malloc_usable_size
#
#   patch_27 只补了前 5 个且全是 host malloc passthrough, host musl
#   堆在高地址 (>4GB), guest 32-bit 槽塞不下. 这版一锅修好.
#
# 设计:
#   - 启动时 mmap 256MB 到 [0x10000000, 0x20000000)
#   - 16B 对齐, 16B header (size + canary), bump 分配
#   - LIFO free: 释放最后一次 alloc 时回退 pos, 复用空间
#   - 非 LIFO free: 标记 canary, 但不回收 (bring-up 阶段 leak)
#   - realloc 缩容/等容原地; 扩容若是 last 分配也原地; 否则新 alloc
#
# TODO[BOX32-prod]:
#   - 真负载下要换 dlmalloc + 低 4GB 池
#   - 256MB 上限不够看到 "low-4GB heap exhausted" 时调大
patch_28_box32_low4gb_allocator() {
    local f="$BOX64/src/musl_compat.c"
    local mark='OHOS_PATCH_BOX32_LOW4GB_V2'

    [ -f "$f" ] || { _patch_header 28 "(skip) musl_compat.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 28 "src/musl_compat.c" "BOX32 low-4GB allocator (v2) — already patched"
        return 0
    fi
    _patch_header 28 "src/musl_compat.c" "complete box32_* allocator suite on low-4GB heap"

    cat >> "$f" << 'EOF_LOW4GB_V2'

/* ============================================================
 * OHOS_PATCH_BOX32_LOW4GB_V2
 * BOX32 低 4GB allocator 全套 (patch 28)
 *
 * 提供 debug.h 引用的全部 7 个 box32_* 入口:
 *   box32_malloc / calloc / realloc / free
 *   box32_memalign / box32_strdup / box32_malloc_usable_size
 *
 * 上层 box64 通过 actual_* 宏在 BOX32 模式下自动路由到这里,
 * 不需要单独 hook box_malloc.
 * ============================================================ */
#include <sys/mman.h>
#include <stdint.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* 前向声明: realloc 内部调 free, free 定义在 realloc 之后,
 * 没有这组 decl 编译器会按 implicit int 推断, 等读到真定义就
 * 报 conflicting types. */
void* box32_malloc(size_t size);
void* box32_calloc(size_t n, size_t s);
void* box32_realloc(void* old, size_t size);
void  box32_free(void* p);
void* box32_memalign(size_t align, size_t size);
char* box32_strdup(const char* s);
size_t box32_malloc_usable_size(void* p);

#define BOX32_HEAP_BASE   ((uintptr_t)0x10000000UL)  /* 256MB 起 */
#define BOX32_HEAP_SIZE   ((size_t)0x10000000UL)     /* 256MB 大小 */
#define BOX32_ALIGN       16
#define BOX32_CANARY      0xB032B032u

#ifndef MAP_FIXED_NOREPLACE
#define MAP_FIXED_NOREPLACE 0x100000
#endif

typedef struct box32_hdr {
    uint32_t size;       /* user-visible size */
    uint32_t canary;     /* BOX32_CANARY 表示 in-use */
} box32_hdr_t;

static unsigned char* g_box32_base = NULL;
static unsigned char* g_box32_pos  = NULL;
static unsigned char* g_box32_end  = NULL;
static unsigned char* g_box32_last = NULL;
static pthread_mutex_t g_box32_mu  = PTHREAD_MUTEX_INITIALIZER;

static void box32_heap_init_locked(void) {
    if (g_box32_base) return;

    void* p = mmap((void*)BOX32_HEAP_BASE, BOX32_HEAP_SIZE,
                   PROT_READ|PROT_WRITE,
                   MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED_NOREPLACE, -1, 0);

    if (p != (void*)BOX32_HEAP_BASE) {
        if (p != MAP_FAILED) munmap(p, BOX32_HEAP_SIZE);
        for (uintptr_t hint = 0x10000000UL; hint < 0x80000000UL;
             hint += 0x10000000UL) {
            p = mmap((void*)hint, BOX32_HEAP_SIZE, PROT_READ|PROT_WRITE,
                     MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
            if (p != MAP_FAILED &&
                (uintptr_t)p + BOX32_HEAP_SIZE <= 0x100000000UL) goto ok;
            if (p != MAP_FAILED) munmap(p, BOX32_HEAP_SIZE);
        }
        fprintf(stderr,
            "OHOS box32: cannot reserve low-4GB heap (%zuMB)\n",
            (size_t)(BOX32_HEAP_SIZE >> 20));
        abort();
    }
ok:
    g_box32_base = (unsigned char*)p;
    g_box32_pos  = g_box32_base;
    g_box32_end  = g_box32_base + BOX32_HEAP_SIZE;
    g_box32_last = NULL;
    fprintf(stderr,
        "OHOS box32: low-4GB heap @%p..%p (%zuMB)\n",
        g_box32_base, g_box32_end,
        (size_t)(BOX32_HEAP_SIZE >> 20));
}

static void* box32_alloc_aligned_locked(size_t user_size, size_t align) {
    if (align < BOX32_ALIGN) align = BOX32_ALIGN;
    /* 当前 pos 之后, 找到 user 对齐位置 */
    uintptr_t hdr_pos = (uintptr_t)g_box32_pos;
    uintptr_t user_pos = (hdr_pos + sizeof(box32_hdr_t) + (align - 1))
                         & ~(uintptr_t)(align - 1);
    uintptr_t end_pos = user_pos + user_size;
    end_pos = (end_pos + (BOX32_ALIGN - 1)) & ~(uintptr_t)(BOX32_ALIGN - 1);

    if (end_pos > (uintptr_t)g_box32_end) return NULL;

    box32_hdr_t* h = (box32_hdr_t*)(user_pos - sizeof(box32_hdr_t));
    h->size   = (uint32_t)user_size;
    h->canary = BOX32_CANARY;

    g_box32_pos  = (unsigned char*)end_pos;
    g_box32_last = (unsigned char*)user_pos;
    return (void*)user_pos;
}

static int box32_free_locked(void* user) {
    if (!user) return 1;
    if ((unsigned char*)user < g_box32_base ||
        (unsigned char*)user >= g_box32_end) return 0;

    box32_hdr_t* h = (box32_hdr_t*)((unsigned char*)user - sizeof(box32_hdr_t));
    if (h->canary != BOX32_CANARY) {
        fprintf(stderr, "OHOS box32: bad free %p (canary=0x%x)\n",
                user, h->canary);
        return 1;
    }

    /* LIFO 复用: 仅回退最后一次 */
    if ((unsigned char*)user == g_box32_last) {
        g_box32_pos  = (unsigned char*)h;
        g_box32_last = NULL;
    }
    h->canary = 0xDEADDEAD;
    return 1;
}

void* box32_malloc(size_t size) {
    if (!size) size = 1;
    pthread_mutex_lock(&g_box32_mu);
    if (!g_box32_base) box32_heap_init_locked();
    void* p = box32_alloc_aligned_locked(size, BOX32_ALIGN);
    pthread_mutex_unlock(&g_box32_mu);
    if (!p) {
        fprintf(stderr,
            "OHOS box32: low-4GB heap exhausted (want=%zu, used=%zuMB/%zuMB)\n",
            size,
            (size_t)((g_box32_pos - g_box32_base) >> 20),
            (size_t)(BOX32_HEAP_SIZE >> 20));
    }
    return p;
}

void* box32_calloc(size_t n, size_t s) {
    size_t total = n * s;
    void* p = box32_malloc(total);
    if (p) memset(p, 0, total);
    return p;
}

void* box32_memalign(size_t align, size_t size) {
    if (align < BOX32_ALIGN) align = BOX32_ALIGN;
    /* power-of-2 检查 */
    if (align & (align - 1)) {
        size_t a = BOX32_ALIGN;
        while (a < align) a <<= 1;
        align = a;
    }
    if (!size) size = 1;
    pthread_mutex_lock(&g_box32_mu);
    if (!g_box32_base) box32_heap_init_locked();
    void* p = box32_alloc_aligned_locked(size, align);
    pthread_mutex_unlock(&g_box32_mu);
    return p;
}

void* box32_realloc(void* old, size_t size) {
    if (!old)  return box32_malloc(size);
    if (!size) { box32_free(old); return NULL; }

    pthread_mutex_lock(&g_box32_mu);
    box32_hdr_t* h = (box32_hdr_t*)((unsigned char*)old - sizeof(box32_hdr_t));
    if (h->canary != BOX32_CANARY) {
        pthread_mutex_unlock(&g_box32_mu);
        fprintf(stderr, "OHOS box32: bad realloc %p\n", old);
        return NULL;
    }
    size_t old_size = h->size;

    /* 缩容 / 等容: 原地 */
    if (size <= old_size) {
        h->size = (uint32_t)size;
        pthread_mutex_unlock(&g_box32_mu);
        return old;
    }

    /* 扩容: 如果是最后一次分配且尾部够空间, 原地扩 */
    if ((unsigned char*)old == g_box32_last) {
        uintptr_t new_end = (uintptr_t)old + size;
        new_end = (new_end + (BOX32_ALIGN - 1)) & ~(uintptr_t)(BOX32_ALIGN - 1);
        if (new_end <= (uintptr_t)g_box32_end) {
            g_box32_pos = (unsigned char*)new_end;
            h->size = (uint32_t)size;
            pthread_mutex_unlock(&g_box32_mu);
            return old;
        }
    }

    /* 否则: 新分配 + 拷贝 + 释放旧 */
    void* np = box32_alloc_aligned_locked(size, BOX32_ALIGN);
    pthread_mutex_unlock(&g_box32_mu);
    if (!np) return NULL;
    memcpy(np, old, old_size);
    box32_free(old);
    return np;
}

void box32_free(void* p) {
    if (!p) return;
    pthread_mutex_lock(&g_box32_mu);
    box32_free_locked(p);
    pthread_mutex_unlock(&g_box32_mu);
}

char* box32_strdup(const char* s) {
    if (!s) return NULL;
    size_t n = strlen(s) + 1;
    char* p = (char*)box32_malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

size_t box32_malloc_usable_size(void* p) {
    if (!p) return 0;
    if ((unsigned char*)p < g_box32_base ||
        (unsigned char*)p >= g_box32_end) return 0;
    box32_hdr_t* h = (box32_hdr_t*)((unsigned char*)p - sizeof(box32_hdr_t));
    if (h->canary != BOX32_CANARY) return 0;
    return h->size;
}
/* OHOS_PATCH_BOX32_LOW4GB_V2 END */
EOF_LOW4GB_V2
}

# ================================================================
# Patch 31 — src/include/box32.h: 关闭 >4GB 指针的 abort 开关
# ================================================================
# 现象:
#   BOX32 加载 libc.so.6, box_strdup("libc.so.6") 返回的 host
#   指针来自 musl 高位 heap (例: 0x55ee2841e8). to_ptrv() 检测到
#   p>>32, 调 box64_abort() 直接退出.
#
# 上游设计:
#   box32.h 顶部:
#     #define TEST32        ← 启用范围检查 (warn)
#     #define TEST_ABORT    ← 命中后 abort
#
#   x86_64 host 上靠 personality(ADDR_LIMIT_32BIT) 把 host 自身
#   就压到 <4GB, 这两个开关组合可以"硬性保证"无泄漏. OHOS HAP
#   拿不到这个 personality, abort 太严苛, box64 自己内部分配的
#   非 guest-visible 指针 (host-only) 也会撞墙.
#
# 修法:
#   #undef TEST_ABORT, 把 abort 路径关掉. 保留 TEST32 仍然走
#   warn 分支, 真有泄漏点会打印 "is not a 32bits value", 我们
#   照旧能定位.
#
# 后续 caveat:
#   关掉 abort 后, 高地址 host 指针被静默截断到低 32 位, 写进
#   i386 槽. guest 后续解引用时多半 SIGSEGV. 这是诊断 patch,
#   目的是让流程往前推, 把"还有哪些 host-only 调用栈漏到 guest
#   slot"全部暴露出来; 之后再决定每个点是改成 box32_* 分配,
#   还是用 shadow id 表代理.
patch_31_box32_no_abort() {
    local f="$BOX64/src/include/box32.h"
    local mark='OHOS_PATCH_BOX32_NO_ABORT'

    [ -f "$f" ] || { _patch_header 31 "(skip) box32.h not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 31 "src/include/box32.h" "no-abort — already patched"
        return 0
    fi
    _patch_header 31 "src/include/box32.h" "disable TEST_ABORT (warn-only on >4GB ptr)"

    # 用注释包住 #define TEST_ABORT 这一行, 不直接删 (方便 grep 查找)
    sed -i 's|^#define TEST_ABORT|/* OHOS_PATCH_BOX32_NO_ABORT: was #define TEST_ABORT */|' "$f"
}

# ================================================================
# Patch 32 — src/include/box32.h: 警告打印加 caller PC + 强制 noinline
# ================================================================
# 目的:
#   patch 31 关掉了 abort, 但 to_ptr/to_ptrv 命中高地址只打 "is not a
#   32bits value" 一行, 看不出是哪条调用站点干的. inline 之后
#   __builtin_return_address(0) 拿到的是更外层 caller, 没用.
#
# 修法:
#   1) 把 4 个 to_* 函数从 "static inline" 改成 "static __attribute__
#      ((noinline))". 文件被多处 include 不会冲突 (static).
#   2) 4 条警告 printf_log 末尾追加 "(caller=%p)" + __builtin_return_
#      address(0), 打出真正的调用点 PC.
#
# 用法:
#   trace 里抓到 3 个 caller=0x... 之后, 在 build host 上跑
#   llvm-addr2line -e build_box64/box64 -f -C -i 0x...
#   就能精确定位是哪个 .c:行号 在塞高地址指针.
patch_32_box32_warn_caller() {
    local f="$BOX64/src/include/box32.h"
    local mark='OHOS_PATCH_BOX32_WARN_CALLER'

    [ -f "$f" ] || { _patch_header 32 "(skip) box32.h not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 32 "src/include/box32.h" "warn caller — already patched"
        return 0
    fi
    _patch_header 32 "src/include/box32.h" "noinline + caller PC in to_*() warnings"

    python3 - "$f" "$mark" << 'PY'
import sys, re
p, mark = sys.argv[1], sys.argv[2]
s = open(p).read()

if mark not in s:
    s = "/* %s */\n" % mark + s

# 4 个函数: TEST32 分支和非 TEST32 分支各一份, 总计 8 处
s = re.sub(r'static\s+inline\s+(ptr_t\s+to_ptr\b)',
           r'static __attribute__((noinline)) \1', s)
s = re.sub(r'static\s+inline\s+(ptr_t\s+to_ptrv\b)',
           r'static __attribute__((noinline)) \1', s)
s = re.sub(r'static\s+inline\s+(long_t\s+to_long\b)',
           r'static __attribute__((noinline)) \1', s)
s = re.sub(r'static\s+inline\s+(ulong_t\s+to_ulong\b)',
           r'static __attribute__((noinline)) \1', s)

s = s.replace(
    'printf_log(LOG_NONE, "Warning, uintptr_t %p is not a 32bits value\\n", (void*)p);',
    'printf_log(LOG_NONE, "Warning, uintptr_t %p is not a 32bits value (caller=%p)\\n", (void*)p, __builtin_return_address(0));'
)
s = s.replace(
    'printf_log(LOG_NONE, "Warning, pointer %p is not a 32bits value\\n", p2);',
    'printf_log(LOG_NONE, "Warning, pointer %p is not a 32bits value (caller=%p)\\n", p2, __builtin_return_address(0));'
)
s = s.replace(
    'printf_log(LOG_NONE, "Warning, long %ld is not a 32bits value\\n", l);',
    'printf_log(LOG_NONE, "Warning, long %ld is not a 32bits value (caller=%p)\\n", l, __builtin_return_address(0));'
)
s = s.replace(
    'printf_log(LOG_NONE, "Warning, ulong %p is not a 32bits value\\n", (void*)l);',
    'printf_log(LOG_NONE, "Warning, ulong %p is not a 32bits value (caller=%p)\\n", (void*)l, __builtin_return_address(0));'
)

open(p, 'w').write(s)
PY
}

# ================================================================
# Patch 33 — src/elfs/elfloader32.c: 预填 globdata stdout/stderr/stdin
# ================================================================
# 现象:
#   glibc 2.34+ i386 binary 的 main 程序对 stdout/stderr 用
#   R_386_GLOB_DAT 而不是 R_386_COPY (老 glibc 风格). box64
#   elfloader32.c:556 处理 R_386_GLOB_DAT 时:
#     if(GetSymbolStartEnd(my_context->globdata, ...))
#         *p = globoffs;       <- 优先走 globdata
#     else
#         *p = offs;            <- fallback: host 真 stdout 高地址
#                                  截断后塞 GOT, guest 自己 deref
#                                  就 SIGSEGV
#   globdata 表只在主 elf 处理 R_386_COPY 时被填. 缺 R_386_COPY
#   就走 fallback. 主 binary main+0x4a 的 SIGSEGV 即此.
#
# 修法:
#   在 GrabX32CopyMainElfReloc 末尾, 为 stdout/stderr/stdin 三个
#   名字预
#     1. box32_malloc(4) 拿一块低 4GB 的 4 字节 slot
#     2. *slot = to_ptrv(my__IO_2_1_*_)  当前是 1/2/3, 也是低值
#     3. AddUniqueSymbol(globdata, "stdout", slot, 4, 2,
#                        "GLIBC_2.0", 1)
#   主 binary R_386_GLOB_DAT 命中 globdata 路径, GOT[stdout]
#   写成 slot (低 4GB), guest deref 拿到 3. wrapper32 的
#   io_convert32() 比较 3 == my__IO_2_1_stdout_(3), 命中,
#   翻译成 host musl stdout 喂给 host fputs/setvbuf. 通.
#
# 为什么改 GrabX32CopyMainElfReloc 末尾:
#   它只跑在主 elf, 时机在所有 reloc 之前. 自带的 GetSymbolStartEnd
#   guard 确保有真 R_386_COPY 的老 binary 不被覆盖.
patch_33_box32_prefill_io_globdata() {
    local f="$BOX64/src/elfs/elfloader32.c"
    local mark='OHOS_PATCH_PREFILL_IO_GLOBDATA'

    [ -f "$f" ] || { _patch_header 33 "(skip) elfloader32.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 33 "src/elfs/elfloader32.c" "prefill IO globdata — already patched"
        return 0
    fi
    _patch_header 33 "src/elfs/elfloader32.c" "prefill globdata stdout/stderr/stdin"

    python3 - "$f" "$mark" << 'PY'
import sys, re
p, mark = sys.argv[1], sys.argv[2]
s = open(p).read()

if mark in s:
    sys.exit(0)

# 找 GrabX32CopyMainElfReloc 的开括号
m = re.search(r'static\s+void\s+GrabX32CopyMainElfReloc\s*\([^)]*\)\s*\{', s)
if not m:
    print("ERROR: GrabX32CopyMainElfReloc not found", file=sys.stderr)
    sys.exit(1)

# 数花括号找匹配的右括号
depth = 1
i = m.end()
while i < len(s) and depth > 0:
    if s[i] == '{':
        depth += 1
    elif s[i] == '}':
        depth -= 1
        if depth == 0:
            break
    i += 1
close_pos = i  # i 指向匹配的 '}'

prefill = '''
    /* MARK_START -- prefill globdata for stdout/stderr/stdin
     *
     * glibc 2.34+ i386 binaries use R_386_GLOB_DAT (not R_386_COPY) for
     * stdout/stderr. Without a globdata entry, R_386_GLOB_DAT falls back
     * to host musl FILE* (high addr), gets truncated, guest deref crashes.
     *
     * We allocate a 4-byte low-4GB slot containing to_ptrv(my__IO_2_1_*_).
     * That low value matches what wrapper32's io_convert32() compares
     * against, so guest passes "3" to e.g. setvbuf, wrapper translates to
     * host musl stdout. Older binaries with real R_386_COPY are skipped
     * by the GetSymbolStartEnd guard.
     */
    {
        extern void* my__IO_2_1_stderr_;
        extern void* my__IO_2_1_stdin_;
        extern void* my__IO_2_1_stdout_;
        extern void* box32_malloc(size_t);
        static const char* const names[3]   = {"stdout", "stderr", "stdin"};
        void* const* const     proxies[3]   = {(void*const*)&my__IO_2_1_stdout_,
                                               (void*const*)&my__IO_2_1_stderr_,
                                               (void*const*)&my__IO_2_1_stdin_};
        for(int k=0; k<3; ++k) {
            uintptr_t exo = 0, exe = 0;
            if(GetSymbolStartEnd(my_context->globdata, names[k],
                                 &exo, &exe, 2, "GLIBC_2.0", 1, 1))
                continue;
            uint32_t* slot = (uint32_t*)box32_malloc(4);
            if(!slot) continue;
            *slot = to_ptrv(*proxies[k]);
            AddUniqueSymbol(my_context->globdata, names[k],
                            (uintptr_t)slot, 4, 2, "GLIBC_2.0", 1);
            printf_log(LOG_DEBUG,
                "OHOS box32: prefilled globdata[__NM__] = __PXVAL__ (slot @__SLOT__)\\n",
                names[k], *proxies[k], slot);
        }
    }
    /* MARK_END */
'''
prefill = prefill.replace('MARK_START', mark + ' START').replace('MARK_END', mark + ' END')
# 把占位符替成真正的 printf 格式符 (避免 python % 干扰)
prefill = prefill.replace('__NM__', '%s').replace('__PXVAL__', '%p').replace('__SLOT__', '%p')

s_new = s[:close_pos] + prefill + s[close_pos:]
open(p, 'w').write(s_new)
PY
}

# ================================================================
# Patch 34 — wrapped32 malloc/free/calloc/... 切到 box32 低 4GB heap
# ================================================================
# 现象:
#   ┌─[ malloc ]
#   [BOX32] Warning, pointer 0x5de3a54700 is not a 32bits value
#   ...
#   │ [INFO] 64=0xe3a54700 4K=0xe3a83000 1M=0xe3a842c0
#   [BOX32] SIGSEGV @0x5de33465f8 box64/free + 0x13
#
# 原因:
#   wrapped32/wrappedlibc.c 注册的 malloc 系列大多是 GO(...) 直通,
#   wrapper 把 host musl malloc 返回的高地址 (>4GB) 通过 to_ptrv()
#   截断后回给 guest. guest 拿到比如 0xe3a54700, free 时 wrapper 用
#   from_ptriv() zero-extend 成 0x00000000_e3a54700 喂给 host musl
#   free, host 发现不是它分配的内存, SIGSEGV.
#
#   现有 my32_malloc 也只是 calloc 直通, 同样高地址.
#
# 修法 (3 步):
#
# A) 重写 my32_malloc 调 box32_malloc (低 4GB heap, patch 28).
#    新增 my32_calloc / realloc / free / memalign / posix_memalign /
#    strdup / strndup / valloc / malloc_usable_size 全套 my32_ 代理,
#    内部全部走 box32_*.
#
# B) wrappedlibc_private.h 把这些 GO/GOW 改成 GOM/GOWM, 让符号映射
#    指向上面新写的 my32_ 实现, 不再直通 host malloc.
#
# C) reallocarray 已经是 GOM, 但实现内部调 host realloc, 改调
#    box32_realloc.
#
# 涵盖范围: malloc/free/calloc/realloc/reallocarray/memalign/
# posix_memalign/valloc/strdup/__strdup/strndup/__strndup/
# malloc_usable_size. 14 个入口够覆盖 test_box64.c 的 malloc 块.
#
# 风险:
# - host libc 内部如果给 guest 返回了一个 host malloc 的指针 (例如
#   getenv 返回值), guest 看到的是高地址截断后的低 32 位, 但 guest
#   通常只是 read 一下字符串内容, 而 host->guest 字符串内容由 wrapper
#   做 io_convert 之外的 from_ptriv 完成, 不一定真断. 出问题再说.
# - posix_memalign 第二个参数是 void**, 不在标准 ABI 上, 这里复用
#   wrapper iEBp_LL (int(int*, ulong, ulong)) 已经能 marshall.
patch_34_box32_alloc_via_low4gb() {
    local f="$BOX64/src/wrapped32/wrappedlibc.c"
    local h="$BOX64/src/wrapped32/wrappedlibc_private.h"
    local mark='OHOS_PATCH_BOX32_ALLOC_LOW4GB'

    [ -f "$f" ] || { _patch_header 34 "(skip) wrappedlibc.c not found" ""; return 0; }
    [ -f "$h" ] || { _patch_header 34 "(skip) wrappedlibc_private.h not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 34 "src/wrapped32/wrappedlibc.c+private.h" "alloc -> box32 — already patched"
        return 0
    fi
    _patch_header 34 "src/wrapped32/wrappedlibc.c+private.h" \
        "route alloc family to box32_* low-4GB heap"

    # ---- A+C: 改写 my32_malloc + my32_reallocarray, 追加新 my32_* ----
    python3 - "$f" "$mark" << 'PY'
import sys, re
p, mark = sys.argv[1], sys.argv[2]
s = open(p).read()
if mark in s:
    sys.exit(0)

# 顶部加 mark + extern 声明
header = (
"/* %s */\n"
"#ifndef BOX64_OHOS_BOX32_ALLOC_GUARD\n"
"#define BOX64_OHOS_BOX32_ALLOC_GUARD 1\n"
"#include <string.h>\n"
"extern void*  box32_malloc(size_t);\n"
"extern void*  box32_calloc(size_t, size_t);\n"
"extern void*  box32_realloc(void*, size_t);\n"
"extern void   box32_free(void*);\n"
"extern void*  box32_memalign(size_t, size_t);\n"
"extern char*  box32_strdup(const char*);\n"
"extern size_t box32_malloc_usable_size(void*);\n"
"#endif\n"
) % mark
s = header + s

# 1. my32_malloc 改成 box32_malloc + memset (保持 'set to zero' 语义)
s = re.sub(
    r'EXPORT\s+void\*\s+my32_malloc\s*\(\s*unsigned\s+long\s+size\s*\)\s*\{[^}]*\}',
    ("EXPORT void* my32_malloc(unsigned long size)\n"
     "{\n"
     "    /* OHOS_PATCH_BOX32_ALLOC_LOW4GB: route to low-4GB heap */\n"
     "    void* p = box32_malloc((size_t)size);\n"
     "    if(p) memset(p, 0, (size_t)size);\n"
     "    return p;\n"
     "}\n"),
    s, count=1, flags=re.S)

# 2. my32_reallocarray 改成 box32_realloc
s = re.sub(
    r'EXPORT\s+void\*\s+my32_reallocarray\s*\(\s*void\*\s*ptr\s*,\s*size_t\s+nmemb\s*,\s*size_t\s+size\s*\)\s*\{[^}]*\}',
    ("EXPORT void* my32_reallocarray(void* ptr, size_t nmemb, size_t size)\n"
     "{\n"
     "    /* OHOS_PATCH_BOX32_ALLOC_LOW4GB */\n"
     "    return box32_realloc(ptr, nmemb * size);\n"
     "}\n"),
    s, count=1, flags=re.S)

# 3. 文件末尾追加新 my32_ 实现
add = '''

/* ============================================================
 * OHOS_PATCH_BOX32_ALLOC_LOW4GB extras
 * 给 free/calloc/realloc/memalign/posix_memalign/strdup/strndup/
 * valloc/malloc_usable_size 提供 my32_ 代理, 全部走 box32 低 4GB heap.
 * ============================================================ */

EXPORT void my32_free(void* p)
{
    box32_free(p);
}

EXPORT void* my32_calloc(size_t nmemb, size_t size)
{
    return box32_calloc(nmemb, size);
}

EXPORT void* my32_realloc(void* p, size_t size)
{
    return box32_realloc(p, size);
}

EXPORT void* my32_memalign(size_t align, size_t size)
{
    return box32_memalign(align, size);
}

EXPORT int my32_posix_memalign(void** memptr, size_t align, size_t size)
{
    if(!memptr) return 22 /* EINVAL */;
    void* p = box32_memalign(align, size);
    if(!p) { *memptr = NULL; return 12 /* ENOMEM */; }
    *memptr = p;
    return 0;
}

EXPORT void* my32_valloc(size_t size)
{
    /* page-aligned, in low-4GB heap */
    return box32_memalign(4096, size);
}

EXPORT char* my32_strdup(const char* s)
{
    return box32_strdup(s);
}

EXPORT char* my32___strdup(const char* s)
{
    return box32_strdup(s);
}

EXPORT char* my32_strndup(const char* s, size_t n)
{
    if(!s) return NULL;
    size_t len = 0;
    while(len < n && s[len]) ++len;
    char* p = (char*)box32_malloc(len + 1);
    if(p) { memcpy(p, s, len); p[len] = 0; }
    return p;
}

EXPORT char* my32___strndup(const char* s, size_t n)
{
    return my32_strndup(s, n);
}

EXPORT size_t my32_malloc_usable_size(void* p)
{
    return box32_malloc_usable_size(p);
}
/* OHOS_PATCH_BOX32_ALLOC_LOW4GB END */
'''

s += add
open(p, 'w').write(s)
PY

    # ---- B: wrappedlibc_private.h 改 GO/GOW -> GOM/GOWM, 并加 //%%,noE ----
    python3 - "$h" "$mark" << 'PY'
import sys, re
p, mark = sys.argv[1], sys.argv[2]
s = open(p).read()
if mark in s:
    sys.exit(0)

# 加 header mark
s = "/* %s */\n" % mark + s

# 把以下符号的 GO -> GOM, GOW -> GOWM, 同时追加 //%%,noE
# (rebuild_wrappers_32.py 要求每个 GOM/GOWM 必须有 //%% 标注,
#  ,noE 表示 my32_ 实现不接受 x64emu_t* 第一参数)
swaps = [
    ('free',              'GO',  'GOM'),
    ('calloc',            'GOW', 'GOWM'),
    ('realloc',           'GO',  'GOM'),
    ('memalign',          'GOW', 'GOWM'),
    ('posix_memalign',    'GOW', 'GOWM'),
    ('valloc',            'GOW', 'GOWM'),
    ('strdup',            'GOW', 'GOWM'),
    ('__strdup',          'GO',  'GOM'),
    ('strndup',           'GOW', 'GOWM'),
    ('__strndup',         'GO',  'GOM'),
    ('malloc_usable_size','GOW', 'GOWM'),
]
n_total = 0
for sym, old, new in swaps:
    # 抓整行: 前缀缩进, GO/GOW(sym, sig), 后续可能有空白和已有注释
    pat = re.compile(
        r'^(\s*)' + old + r'\(\s*' + re.escape(sym) + r'\s*,([^\n)]*)\)\s*$',
        re.M)
    new_s, n = pat.subn(
        r'\1' + new + r'(' + sym + r',\2)  //%%,noE',
        s)
    if n != 1:
        print(f"WARN: swap {sym} {old}->{new} matched {n} times", file=sys.stderr)
    s = new_s
    n_total += n
print(f"  patch_34 private.h: {n_total} swaps applied")
open(p, 'w').write(s)
PY
}

# ================================================================
# Patch 35 — box32 iomap: 动态 FILE* 双向代理
# ================================================================
# 现象:
#   ┌─[ file_io ]
#   [BOX32] Warning, pointer 0x66d7a3e6c8 is not a 32bits value (caller=...)
#   [BOX32] SIGSEGV @ box64/fwrite + 0x13, accessing 0xd7a3e764
#
# 原因:
#   patch 33 解决了"命名"FILE*(stdout/stderr/stdin)的 GLOB_DAT 截断,
#   靠的是 wrapper32.c 自带的 io_convert32/io_convert_from 三个特例
#   (my__IO_2_1_stdout_ 等). 但 fopen 返回的"动态" FILE* 是 host musl
#   heap 上的高地址(>4GB), io_convert_from 不识别, 直接 to_ptrv 截断
#   写到 guest. guest fwrite 把截断的指针传回, io_convert32 也不识别,
#   直接 from_ptriv zero-extend 喂给 host musl fwrite -> 解引用野指针
#   -> SIGSEGV.
#
# 修法 (3 步):
#
# A) 在 musl_compat.c 末尾加 box32 iomap:
#    - 1024 槽数组(host_FILE* <-> guest 32-bit slot 双向映射)
#    - box32_io_from_host(host*) -> 32bit slot (新 host* 自动注册)
#    - box32_io_to_host(slot)    -> host* (查表)
#    - box32_io_unregister(slot) -> 释放槽 (fclose 用)
#    - 内置 stdin/stderr/stdout 三个特例 (绕过 my__IO_2_1_*_)
#    用线性查找(O(N)) -- N<=1024 时常数因子比 hash 还低
#
# B) Patch rebuild_wrappers_32.py 让生成的 io_convert32 / io_convert_from
#    函数体改成纯 forward 调 box32_io_*. 因为 wrapper32.c 是 cmake build
#    target, 改完 generator 自动重新生成. 所有标 'S' 类型签名(30+ 个 stdio
#    函数)自动通过新的 io_convert.
#
# C) fclose 改 GOM my32_fclose, 调 box32_io_unregister 释放 slot 后
#    forward 给 host fclose.
#
# 风险:
# - guest 自己 deref FILE* (例如 i386 glibc 内联读 _flags) 拿到 slot 地址
#   解引用 4 字节(我们存的是 host_FILE 高位指针的低 32 位, 其实是垃圾值),
#   会触发 SIGSEGV. 但典型 stdio 用法都走库函数, 不直接读字段, 现实风险
#   低. 真碰到再补"slot 内填 host FILE 完整副本"的代理.
patch_35_box32_iomap() {
    local f_compat="$BOX64/src/musl_compat.c"
    local f_gen="$BOX64/rebuild_wrappers_32.py"
    local f_libc="$BOX64/src/wrapped32/wrappedlibc.c"
    local f_priv="$BOX64/src/wrapped32/wrappedlibc_private.h"
    local mark='OHOS_PATCH_BOX32_IOMAP'

    [ -f "$f_compat" ] || { _patch_header 35 "(skip) musl_compat.c not found" ""; return 0; }
    [ -f "$f_gen" ]    || { _patch_header 35 "(skip) rebuild_wrappers_32.py not found" ""; return 0; }
    [ -f "$f_libc" ]   || { _patch_header 35 "(skip) wrappedlibc.c not found" ""; return 0; }
    [ -f "$f_priv" ]   || { _patch_header 35 "(skip) wrappedlibc_private.h not found" ""; return 0; }

    if _already "$f_compat" "$mark"; then
        _patch_header 35 "iomap" "already patched"
        return 0
    fi
    _patch_header 35 "iomap" "box32 dynamic FILE* proxy via 1024-slot table"

    # ---- A) musl_compat.c 末尾追加 box32 iomap 实现 ----
    cat >> "$f_compat" << EOF_IOMAP_HEAD
/* $mark START */
EOF_IOMAP_HEAD

    cat >> "$f_compat" << 'EOF_IOMAP'
/* ============================================================
 * OHOS_PATCH_BOX32_IOMAP — box32 动态 FILE* 双向代理
 *
 * box64 上游 wrapper32 用 io_convert32/io_convert_from 处理
 * stdin/stderr/stdout 三个全局 FILE*. 但 fopen 返回的动态
 * FILE* 是 host musl 高位地址, 没法用 to_ptrv 直接截断后
 * 让 guest 持有 (guest 后续 fwrite/fclose 时拿截断地址回头喂
 * host musl 必然 SIGSEGV).
 *
 * 解决: 维护一张固定大小的双向表
 *   slot[i] = host_FILE*       (低 4GB 的 4 字节 ID 给 guest)
 *   guest_id = (uint32_t)slot_addr  (其实就是 &slot[i] 的低 32 位)
 *
 * guest 视角拿到的 FILE* = &slot[i] (低 4GB heap 地址),
 * 一旦回到 wrapper, io_convert32 反查 slot 数组拿到 host*.
 *
 * 用 1024 槽够用 (test 程序最多开 10 个 FILE*; 实际负载里
 * 也很少超过几十). 超了 abort 提示扩容.
 * ============================================================ */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

extern void* box32_malloc(size_t);
extern void  box32_free(void*);

#define BOX32_IOMAP_CAP 1024

/* 每个 slot 是低 4GB 上 4 字节, 内容存 host* 高位低 32 位 (其实只是
 * 给 guest 自己 deref *fp 至少看到点东西的占位; 主要 routing 逻辑
 * 不依赖 slot 内容, 而是 slot 地址). */
typedef struct {
    void*   host;       /* host FILE*; NULL 表示空槽 */
    void*   guest_slot; /* 低 4GB 的 4 字节 slot 地址 */
} box32_iomap_entry_t;

static box32_iomap_entry_t g_iomap[BOX32_IOMAP_CAP];
static int                 g_iomap_used = 0;
static pthread_mutex_t     g_iomap_mu = PTHREAD_MUTEX_INITIALIZER;

/* host -> guest: 找已注册槽, 没有就分配新槽 */
void* box32_io_from_host(void* host) {
    if (!host) return NULL;
    /* stdin/stderr/stdout 走特例 (调用方 io_convert_from 已先匹配),
     * 这里仍兜底保护一次: 三个全局直接返回固定低值 1/2/3 占位.
     * box64 上游 my__IO_2_1_*_ 默认 1/2/3, 这与 patch 33 globdata
     * prefill 写入的值一致. */
    if (host == stdin)  return (void*)(uintptr_t)2;
    if (host == stdout) return (void*)(uintptr_t)3;
    if (host == stderr) return (void*)(uintptr_t)1;

    pthread_mutex_lock(&g_iomap_mu);
    /* 查重 */
    for (int i = 0; i < BOX32_IOMAP_CAP; ++i) {
        if (g_iomap[i].host == host) {
            void* gs = g_iomap[i].guest_slot;
            pthread_mutex_unlock(&g_iomap_mu);
            return gs;
        }
    }
    /* 新分配 */
    if (g_iomap_used >= BOX32_IOMAP_CAP) {
        pthread_mutex_unlock(&g_iomap_mu);
        fprintf(stderr,
            "OHOS box32 iomap exhausted (%d slots). Increase BOX32_IOMAP_CAP.\n",
            BOX32_IOMAP_CAP);
        abort();
    }
    int idx = -1;
    for (int i = 0; i < BOX32_IOMAP_CAP; ++i) {
        if (!g_iomap[i].host) { idx = i; break; }
    }
    if (idx < 0) {
        pthread_mutex_unlock(&g_iomap_mu);
        abort();   /* unreachable */
    }
    void* slot = box32_malloc(4);
    if (!slot) {
        pthread_mutex_unlock(&g_iomap_mu);
        return NULL;
    }
    /* slot 内容: 写 host 高位地址的低 32 位作为 marker.
     * guest 真去 deref *fp 不会立刻 segfault (slot 是低 4GB 可读),
     * 但内容是垃圾 -- 假定 guest 不会 walk FILE 内部字段.
     * 如果将来需要支持, 改成 memcpy 一份 i386 FILE 镜像即可. */
    *(uint32_t*)slot = (uint32_t)((uintptr_t)host & 0xFFFFFFFFu);

    g_iomap[idx].host       = host;
    g_iomap[idx].guest_slot = slot;
    g_iomap_used++;

    pthread_mutex_unlock(&g_iomap_mu);
    return slot;
}

/* guest -> host: 反查槽 */
void* box32_io_to_host(void* guest) {
    if (!guest) return NULL;
    /* 特例: 1/2/3 表示 stderr/stdin/stdout (与 my__IO_2_1_*_ 默认值
     * 和 patch 33 prefill 一致). 注意上游 wrapper 调用顺序是先 my__IO
     * 比较再走我们这里, 所以这层兜底在动态 slot 不命中时才生效. */
    uintptr_t v = (uintptr_t)guest;
    if (v == 1) return stderr;
    if (v == 2) return stdin;
    if (v == 3) return stdout;

    pthread_mutex_lock(&g_iomap_mu);
    for (int i = 0; i < BOX32_IOMAP_CAP; ++i) {
        if (g_iomap[i].guest_slot == guest) {
            void* h = g_iomap[i].host;
            pthread_mutex_unlock(&g_iomap_mu);
            return h;
        }
    }
    pthread_mutex_unlock(&g_iomap_mu);
    /* 没注册过 -- 当成已经是 host* (兼容老路径) */
    return guest;
}

/* fclose 调: 释放 slot, 返回真正的 host FILE* 给 host fclose */
void* box32_io_unregister(void* guest) {
    if (!guest) return NULL;
    uintptr_t v = (uintptr_t)guest;
    if (v == 1) return stderr;
    if (v == 2) return stdin;
    if (v == 3) return stdout;

    pthread_mutex_lock(&g_iomap_mu);
    for (int i = 0; i < BOX32_IOMAP_CAP; ++i) {
        if (g_iomap[i].guest_slot == guest) {
            void* h = g_iomap[i].host;
            box32_free(g_iomap[i].guest_slot);
            g_iomap[i].host       = NULL;
            g_iomap[i].guest_slot = NULL;
            g_iomap_used--;
            pthread_mutex_unlock(&g_iomap_mu);
            return h;
        }
    }
    pthread_mutex_unlock(&g_iomap_mu);
    return guest;
}
/* OHOS_PATCH_BOX32_IOMAP END */
EOF_IOMAP

    # ---- B) 改 rebuild_wrappers_32.py 让生成器输出 forward shim ----
    python3 - "$f_gen" "$mark" << 'PY'
import sys, re
p, mark = sys.argv[1], sys.argv[2]
s = open(p).read()
if mark in s:
    sys.exit(0)

# 在文件最前面加注释标记
s = "# %s\n" % mark + s

# 替换 io_convert32 函数体: 整段从 'static void* io_convert32(void* v)'
# 到对应的 '{rbr}' 闭合
new_io_convert32 = '''static void* io_convert32(void* v)
            {lbr}
                    extern void* box32_io_to_host(void*);
                    return box32_io_to_host(v);
            {rbr}'''

new_io_convert_from = '''static void* io_convert_from(void* v)
            {lbr}
                    extern void* box32_io_from_host(void*);
                    return box32_io_from_host(v);
            {rbr}'''

# 用非贪婪匹配抓两个函数体
pat32 = re.compile(
    r'static void\* io_convert32\(void\* v\)\s*\n'
    r'\s*\{lbr\}.*?\{rbr\}', re.S)
pat_from = re.compile(
    r'static void\* io_convert_from\(void\* v\)\s*\n'
    r'\s*\{lbr\}.*?\{rbr\}', re.S)

s, n1 = pat32.subn(new_io_convert32, s)
s, n2 = pat_from.subn(new_io_convert_from, s)
print(f"  patch_35 generator: io_convert32 x{n1}, io_convert_from x{n2}")
if n1 != 1 or n2 != 1:
    print("ERROR: io_convert* substitution failed", file=sys.stderr)
    sys.exit(1)
open(p, 'w').write(s)
PY

    # ---- C) wrappedlibc.c 末尾追加 my32_fclose ----
    cat >> "$f_libc" << 'EOF_FCLOSE'

/* OHOS_PATCH_BOX32_IOMAP fclose proxy */
extern void* box32_io_unregister(void*);
EXPORT int my32_fclose(void* guest_fp)
{
    void* host = box32_io_unregister(guest_fp);
    if (!host) return 0;
    /* 三个全局 FILE* 不真关 */
    if (host == stdin || host == stdout || host == stderr) return 0;
    return fclose((FILE*)host);
}
/* OHOS_PATCH_BOX32_IOMAP fclose END */
EOF_FCLOSE

    # ---- D) wrappedlibc_private.h: fclose GO -> GOM ----
    python3 - "$f_priv" "$mark" << 'PY'
import sys, re
p, mark = sys.argv[1], sys.argv[2]
s = open(p).read()
if mark in s:
    sys.exit(0)
s = "/* %s */\n" % mark + s

# fclose: GO(fclose, iES)  ->  GOM(fclose, iES)  //%%,noE
pat = re.compile(r'^(\s*)GO\(\s*fclose\s*,([^\n)]*)\)\s*$', re.M)
new_s, n = pat.subn(r'\1GOM(fclose,\2)  //%%,noE', s)
if n != 1:
    print(f"ERROR: GO(fclose,...) match count = {n}", file=sys.stderr)
    sys.exit(1)
open(p, 'w').write(new_s)
PY
}

# ================================================================
# Patch 50 — V4: SIGSYS fallback handler (HAP seccomp 兼容)
# ================================================================
# HarmonyOS HAP 沙箱用 seccomp 白名单, 被拒的 syscall 默认会发
# SIGSYS 直接 kill 进程. 装一个 handler 拦住, 把 ucontext 里的
# 返回值寄存器改成 -ENOSYS, 让 musl libc 走 fallback 路径.
#
# 在 ctor(101) 里自动装一次 (做兜底), 同时通过
# box64_install_sigsys_fallback() 暴露成手动入口给 box64_run()
# 显式调用 (走 .so 路径时 ctor 已经能工作, 但显式调用更可控).

patch_50_sigsys_fallback() {
    local f="$BOX64/src/sigsys_fallback.c"
    if [ -f "$f" ] && grep -q 'BOX64_OHOS_SIGSYS' "$f"; then
        _patch_header 50 "src/sigsys_fallback.c" "SIGSYS — already patched"
        return 0
    fi
    _patch_header 50 "src/sigsys_fallback.c" "create SIGSYS->ENOSYS handler"

    cat > "$f" << 'EOF_SIGSYS'
/* BOX64_OHOS_SIGSYS — patch 50
 *
 * SIGSYS fallback for HarmonyOS seccomp white-list policy.
 * 把被 seccomp 拦下的 syscall 伪造成 -ENOSYS 让 libc 走 fallback.
 */
#define _GNU_SOURCE
#include <signal.h>
#include <ucontext.h>
#include <errno.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>

static void box64_sigsys_handler(int sig, siginfo_t *info, void *ucontext) {
    (void)sig;
    ucontext_t *uc = (ucontext_t*)ucontext;
    int nr = info->si_syscall;
#if defined(__aarch64__)
    uc->uc_mcontext.regs[0] = (unsigned long)(-ENOSYS);
#elif defined(__x86_64__)
    uc->uc_mcontext.gregs[REG_RAX] = (greg_t)(-ENOSYS);
#elif defined(__arm__)
    uc->uc_mcontext.arm_r0 = (unsigned long)(-ENOSYS);
#endif
    char msg[96];
    int n = snprintf(msg, sizeof(msg),
                     "[box64] SIGSYS caught: nr=%d -> ENOSYS\n", nr);
    if (n > 0) (void)!write(2, msg, (size_t)n);
}

void box64_install_sigsys_fallback(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = box64_sigsys_handler;
    sa.sa_flags = SA_SIGINFO | SA_RESTART;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSYS, &sa, NULL) != 0) {
        const char *e = "[box64] WARN: install SIGSYS handler failed\n";
        (void)!write(2, e, strlen(e));
    } else {
        const char *m = "[box64] SIGSYS fallback installed\n";
        (void)!write(2, m, strlen(m));
    }
}

__attribute__((constructor(101)))
static void box64_sigsys_ctor(void) {
    box64_install_sigsys_fallback();
}
EOF_SIGSYS
}

# ================================================================
# Patch 51 — V4: box64_run() 导出入口
# ================================================================
# HAP NAPI 调用契约:
#   1. NAPI 进程 fork()
#   2. 子进程 dlopen("libbox64.so", RTLD_NOW|RTLD_GLOBAL)
#   3. dlsym 拿 box64_run, 调 box64_run(argc, argv, env)
#   4. box64_run 重装 SIGSYS handler 后转给 box64_main
#
# argv[0] 通常 "box64", argv[1] 是 guest x86 ELF 路径.

patch_51_box64_run_entry() {
    local f="$BOX64/src/box64_so_entry.c"
    if [ -f "$f" ] && grep -q 'BOX64_OHOS_SO_ENTRY' "$f"; then
        _patch_header 51 "src/box64_so_entry.c" "box64_run — already patched"
        return 0
    fi
    _patch_header 51 "src/box64_so_entry.c" "create exported box64_run entrypoint"

    cat > "$f" << 'EOF_SOENTRY'
/* BOX64_OHOS_SO_ENTRY — patch 51
 *
 * Exported entry for HAP NAPI:
 *   pid_t pid = fork();
 *   if (pid == 0) {
 *       void* h = dlopen("libbox64.so", RTLD_NOW|RTLD_GLOBAL);
 *       int (*f)(int, const char**, const char**) = dlsym(h, "box64_run");
 *       _exit(f(argc, argv, env));
 *   }
 */
extern int  box64_main(int argc, const char** argv, const char** env);
extern void box64_install_sigsys_fallback(void);

__attribute__((visibility("default")))
int box64_run(int argc, const char** argv, const char** env)
{
    box64_install_sigsys_fallback();
    return box64_main(argc, argv, env);
}
EOF_SOENTRY
}

# ================================================================
# Patch 52 — V4: src/main.c — int main → int box64_main
# ================================================================
# .so 没有 main() 入口, 把 box64 的 main 改名让 box64_so_entry.c
# 通过 box64_run() 转发. 签名不变.

patch_52_rename_main() {
    local f="$BOX64/src/main.c"
    [ -f "$f" ] || { _patch_header 52 "(skip) src/main.c not found" ""; return 0; }
    if grep -q '^int box64_main(' "$f"; then
        _patch_header 52 "src/main.c" "main->box64_main — already patched"
        return 0
    fi
    if ! grep -q '^int main(' "$f"; then
        echo "ERROR: src/main.c 找不到 'int main(' 行"
        return 1
    fi
    _patch_header 52 "src/main.c" "rename main -> box64_main"
    sed -i 's/^int main(/int box64_main(/' "$f"
}

# ================================================================
# Patch 53 — V4: CMakeLists.txt 切到 SHARED + 注入 .so 入口源
# ================================================================
# box64 主 target 从 add_executable 切成 add_library(... SHARED),
# sigsys_fallback.c / box64_so_entry.c 加进 sources, 强制 PIC +
# visibility=default. 最终产物 libbox64.so.
#
# box64 上游 CMakeLists 里 target 行写法是:
#   add_executable(${BOX64} ${SRC} ${WRAPPEDS} ${WRAPPEDS32} ${DYNAREC_S})
# BOX64 变量值是 "box64".

patch_53_cmake_to_shared() {
    local cm="$BOX64/CMakeLists.txt"
    local mark='OHOS_PATCH_V4_SO_BUILD'

    [ -f "$cm" ] || { _patch_header 53 "(skip) CMakeLists.txt not found" ""; return 0; }
    if _already "$cm" "$mark"; then
        _patch_header 53 "CMakeLists.txt" "SHARED build — already patched"
        return 0
    fi
    _patch_header 53 "CMakeLists.txt" "add_executable -> add_library SHARED + so entry sources"

    # 1) add_executable(${BOX64} ... -> add_library(${BOX64} SHARED ...
    sed -i 's|add_executable(${BOX64}|add_library(${BOX64} SHARED|' "$cm"

    # 2) 末尾追加 V4 配置块 (硬编码 mark, 用 'EOF' 防 bash 展开)
    cat >> "$cm" << 'EOF_SO_BUILD'

# OHOS_PATCH_V4_SO_BUILD =====================
if(TARGET box64)
    target_sources(box64 PRIVATE
        ${CMAKE_SOURCE_DIR}/src/sigsys_fallback.c
        ${CMAKE_SOURCE_DIR}/src/box64_so_entry.c)
    set_target_properties(box64 PROPERTIES
        POSITION_INDEPENDENT_CODE  ON
        C_VISIBILITY_PRESET        default
        VISIBILITY_INLINES_HIDDEN  OFF
        OUTPUT_NAME                box64
        PREFIX                     lib)
endif()
# ============================================
EOF_SO_BUILD
}

# ================================================================
# Patch 36 — V4: MAP_32BIT hard search via MAP_FIXED_NOREPLACE
# ================================================================
# 现象 (HAP 沙箱内):
#   [BOX32] Stack pointer too high (0xffffffffffffffff), aborting
#   死循环 + low-4GB heap exhausted + SIGSEGV
#
# 原因:
#   1) ARM64 内核不识别 MAP_32BIT (x86_64-only Linux flag).
#   2) box_mmap 的 fallback 依赖 box64 内部 mapallmem 红黑树,
#      但 mapallmem 在 HAP 沙箱内不够准, find31bitBlockNearHint
#      经常返回 NULL.
#   3) 拿到 NULL 后 MAP_FIXED 不加, 又是 hint-only mmap, 内核
#      给高地址或失败.
#
# 修法:
#   在 box_mmap 入口拦截 MAP_32BIT, 用 MAP_FIXED_NOREPLACE 自己
#   从 0x40000000 开始按 64KB 步长扫到 ~4GB 上限. 不依赖 mapallmem,
#   直接探内核. 静态游标加速.
#
#   起点 0x40000000 故意留出:
#     [0x10000000, 0x20000000)  patch 28 box32 低 4GB heap
#     [0x20000000, 0x40000000)  缓冲, 防 box32 heap 之外的小分配冲突
patch_36_box32_mmap_hard_search() {
    local f="$BOX64/src/custommem.c"
    local mark='OHOS_PATCH_BOX32_MMAP_HARD_SEARCH'
    [ -f "$f" ] || { _patch_header 36 "(skip) custommem.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 36 "src/custommem.c" "MAP_32BIT hard search — already"
        return 0
    fi
    _patch_header 36 "src/custommem.c" "MAP_32BIT hard search via MAP_FIXED_NOREPLACE"

    # A) 文件末尾追加 hard search 实现
    cat >> "$f" << 'EOF_HARDSEARCH'

/* ============================================================
 * OHOS_PATCH_BOX32_MMAP_HARD_SEARCH (patch 36)
 *
 * 完全旁路 box64 自带 find31bitBlockNearHint + mapallmem 路径.
 * 用 MAP_FIXED_NOREPLACE 让内核直接告诉我们某个地址能不能用.
 * 范围 [0x40000000, 0xff000000). 64KB 步长. 静态游标.
 * ============================================================ */
#ifndef MAP_FIXED_NOREPLACE
#define MAP_FIXED_NOREPLACE 0x100000
#endif

void* box_mmap32_hard_search_ohos(size_t length, int prot, int flags,
                                  int fd, ssize_t offset)
{
    static uintptr_t cursor = 0x40000000UL;
    static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    static const uintptr_t LO = 0x40000000UL;
    static const uintptr_t HI = 0xff000000UL;

    int base_flags = flags & ~MAP_32BIT;
    base_flags &= ~MAP_FIXED;

    /* 64KB align */
    size_t len = (length + 0xffffUL) & ~(size_t)0xffffUL;
    if (len == 0) len = 0x10000;

    pthread_mutex_lock(&mu);

    /* 两轮: 第一轮从 cursor 到 HI; 第二轮 wrap 回 LO 到 cursor */
    for (int round = 0; round < 2; round++) {
        uintptr_t cur = (round == 0) ? cursor : LO;
        uintptr_t end = (round == 0) ? HI    : cursor;

        while (cur + len <= end) {
            void* ret = InternalMmap((void*)cur, len, prot,
                                     base_flags | MAP_FIXED_NOREPLACE,
                                     fd, offset);
            if (ret != MAP_FAILED) {
                if ((uintptr_t)ret == cur &&
                    (uintptr_t)ret + len <= 0x100000000UL) {
                    cursor = cur + len;
                    if (cursor + 0x10000 > HI) cursor = LO;
                    pthread_mutex_unlock(&mu);
                    return ret;
                }
                /* kernel didn't honor NOREPLACE, undo */
                InternalMunmap(ret, len);
            }
            cur += 0x10000;
        }
    }

    pthread_mutex_unlock(&mu);
    return MAP_FAILED;
}
/* OHOS_PATCH_BOX32_MMAP_HARD_SEARCH END */
EOF_HARDSEARCH

    # B) 在 box_mmap 函数顶部插短路
    python3 - "$f" "$mark" << 'PY'
import sys, re
p, mark = sys.argv[1], sys.argv[2]
s = open(p).read()

if mark + '_HOOK' in s:
    sys.exit(0)

m = re.search(
    r'EXPORT void\* box_mmap\(void \*addr, size_t length, int prot, '
    r'int flags, int fd, ssize_t offset\)\s*\{',
    s)
if not m:
    print("ERROR: box_mmap signature not found", file=sys.stderr)
    sys.exit(1)

inject = '''
    /* OHOS_PATCH_BOX32_MMAP_HARD_SEARCH_HOOK */
    {
        extern void* box_mmap32_hard_search_ohos(size_t, int, int, int, ssize_t);
        if((flags & MAP_32BIT) && !(flags & MAP_FIXED) && !addr) {
            void* hs = box_mmap32_hard_search_ohos(length, prot, flags,
                                                    fd, offset);
            if(hs != MAP_FAILED) return hs;
            /* fall through to original logic if hard search exhausted */
        }
    }
'''

ins = m.end()
s_new = s[:ins] + inject + s[ins:]
open(p, 'w').write(s_new)
print("  patch_36: box_mmap intercept inserted")
PY
}

# ================================================================
# Patch 62 — src/wrapped/wrappedlibc.c: my_mmap64 NOREPLACE fallback
# ================================================================
# 现象:
#   wine ntdll.so 启动期连续探测高位 VA, 全部返回 ENOSYS:
#     mmap(0x8000000000000000, 0x1000, 0x0, 0x100022, -1, 0)  -> ENOSYS
#     mmap(0x400000000,        0x1000, 0x0, 0x100022, -1, 0)  -> ENOSYS
#     mmap(0x100000000,        0x1000, 0x0, 0x100022, -1, 0)  -> ENOSYS
#   ntdll 看见 ENOSYS 直接 exit(1).
#
# 根因:
#   HAP seccomp policy 用 SECCOMP_RET_ERRNO(ENOSYS) 静默拒绝带
#   MAP_FIXED_NOREPLACE (0x100000) 的 mmap. 不发 SIGSYS, 所以 patch 50
#   的 handler 完全没参与, 错误码 ENOSYS 直接透传给 guest.
#
#   上游 wrappedlibc.c:3645 本来有 fallback 块, 但被整段注释了.
#
# 修法:
#   在 my_mmap64 调 box_mmap 之后加一个 retry: 如果返回 ENOSYS/EINVAL
#   且 flags 含 MAP_FIXED_NOREPLACE, 就 strip 这个 flag 重试. 重试后
#   如果内核给的地址不是请求的 addr, 用 munmap + EEXIST 模拟 NOREPLACE
#   语义 (调用方拿到 EEXIST 与真正的 NOREPLACE 行为一致, 会试下一个 addr).
#
# 影响范围:
#   覆盖 my_mmap / my_mmap64 (alias). 32-bit guest (my32_mmap) 暂不修,
#   wine x86_64 不走那条路径.
patch_62_mmap_noreplace_fallback() {
    local f="$BOX64/src/wrapped/wrappedlibc.c"
    local mark='OHOS_PATCH_MMAP_NOREPLACE_FALLBACK'

    [ -f "$f" ] || { _patch_header 62 "(skip) wrappedlibc.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 62 "src/wrapped/wrappedlibc.c" "MAP_FIXED_NOREPLACE fallback — already"
        return 0
    fi
    _patch_header 62 "src/wrapped/wrappedlibc.c" "seccomp ENOSYS fallback for MAP_FIXED_NOREPLACE"

    python3 - "$f" "$mark" << 'PY'
import sys
p, mark = sys.argv[1], sys.argv[2]
s = open(p).read()
if mark in s:
    sys.exit(0)

old = (
    '    void* ret = box_mmap(addr, length, prot, flags, fd, offset);\n'
    '    int e = errno;\n'
)
n = s.count(old)
if n != 1:
    print("ERROR: my_mmap64 target string count=%d (need 1)" % n, file=sys.stderr)
    sys.exit(1)

new = '''    /* OHOS_PATCH_MMAP_NOREPLACE_FALLBACK START
     * HAP seccomp denies mmap with MAP_FIXED_NOREPLACE via
     * SECCOMP_RET_ERRNO(ENOSYS). Retry without the flag and
     * simulate NOREPLACE semantics by checking returned address.
     * Without this, wine/ntdll fails VA probing and exits. */
#ifndef BOX64_OHOS_MAP_FIXED_NOREPLACE
#define BOX64_OHOS_MAP_FIXED_NOREPLACE 0x100000
#endif
    void* ret = box_mmap(addr, length, prot, flags, fd, offset);
    int e = errno;
    if (ret == MAP_FAILED && (e == ENOSYS || e == EINVAL)
        && (flags & BOX64_OHOS_MAP_FIXED_NOREPLACE)
        && !(flags & MAP_FIXED) && addr) {
        int fb_flags = flags & ~BOX64_OHOS_MAP_FIXED_NOREPLACE;
        ret = box_mmap(addr, length, prot, fb_flags, fd, offset);
        e = errno;
        if (ret != MAP_FAILED && (uintptr_t)ret != (uintptr_t)addr) {
            /* hint not honored -> caller asked NOREPLACE, fail with EEXIST */
            box_munmap(ret, length);
            ret = MAP_FAILED;
            e = EEXIST;
        }
    }
    /* OHOS_PATCH_MMAP_NOREPLACE_FALLBACK END */
'''

s = s.replace(old, new, 1)
open(p, 'w').write(s)
PY
}

# ================================================================
# Patch 63 — src/tools/wine_tools.c: 给 KUSER_SHARED_DATA 留洞
# ================================================================
# 现象:
#   wine ntdll 启动期调
#     mmap(0x7ffe0000, 0x1000, PROT_READ,
#          MAP_FIXED_NOREPLACE|MAP_PRIVATE|MAP_ANON, -1, 0)
#   box64 的 wine prereserve 表第 3 条 {0x7f000000, 0x03000000} 把
#   [0x7f000000, 0x82000000) 整段占了, 包含 0x7ffe0000. Patch 62 的
#   NOREPLACE fallback 因为地址被占, 退回 EEXIST 给 wine, wine exit(1).
#
#   0x7ffe0000 是 Windows ABI 强制的 KUSER_SHARED_DATA 绝对地址,
#   wine ntdll 必须能拿到这一页. 真 Linux 上 wine-preloader 也是这么做的:
#   prereserve 时给它留一个 4KB 洞.
#
# 修法:
#   把第 3 条 prereserve 拆成两条, 中间跳过 0x7ffe0000 这 1 页:
#     {0x7f000000, 0x00fe0000}  -- 覆盖 [0x7f000000, 0x7ffe0000)
#     {0x7ffe1000, 0x0201f000}  -- 覆盖 [0x7ffe1000, 0x82000000)
#   尺寸合计 0x00fe0000 + 0x0201f000 = 0x02fff000 = 原 0x03000000 - 0x1000,
#   差的正是给 wine 留的那 1 页.
#
#   数组 my_wine_reserve[] 没指定固定大小, 原本 3 真 + 2 哨兵 = 5 槽,
#   拆完变成 4 真 + 1 哨兵, 仍是 5 槽, 不撑爆.
patch_63_wine_kuser_hole() {
    local f="$BOX64/src/tools/wine_tools.c"
    local mark='OHOS_PATCH_WINE_KUSER_HOLE'

    [ -f "$f" ] || { _patch_header 63 "(skip) wine_tools.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 63 "src/tools/wine_tools.c" "KUSER_SHARED_DATA hole — already"
        return 0
    fi
    _patch_header 63 "src/tools/wine_tools.c" "carve 0x7ffe0000 hole out of wine prereserve"

    sed -i "1i\\
/* $mark */" "$f"

    # 用 python 而不是 sed: 长字符串 + 多个 *, 转义太啰嗦, 且要确认命中.
    python3 - "$f" << 'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()

old = ('{(void*)0x7f000000, 0x03000000}, '
       '{0, 0}, {0, 0}')
new = ('{(void*)0x7f000000, 0x00fe0000}, '
       '{(void*)0x7ffe1000, 0x0201f000}, '
       '{0, 0}')

if old not in s:
    print("ERROR: prereserve table line not found exactly", file=sys.stderr)
    sys.exit(1)

s = s.replace(old, new, 1)
open(p, 'w').write(s)
PY
}

# ================================================================
# Patch 65 — HAP /tmp 路径重映射 (proot 风格 path translation)
# ================================================================
# 现象:
#   wine + wineserver 把 /tmp/.wine-${UID}/server-${dev}-${ino} 当成
#   wineserver 通信目录, 路径在 wine 二进制里硬编码. HAP 沙箱里 /tmp
#   不存在, mkdir/connect 全部 ENOENT, wineserver 无法启动.
#
# 修法:
#   在 box64 wrapper 边界做 proot 式 path translation.
#   guest 看到的还是 "/tmp/...", host musl 真实拿到的是
#   "${TMPDIR}/box64-tmp/..." (HAP 可写目录).
#
#   核心库:
#     box64_remap_path()         前缀匹配 + 改写, 复用 PATH_MAX 栈缓冲
#     box64_remap_sockaddr_un()  AF_UNIX sun_path 改写 (bind/connect)
#
#   挂钩点 (第一波, 覆盖 wineserver 启动路径):
#     - my_open64   (已有实现, 注入 remap 到函数顶部)
#     - my_lstat    (已有, my_lstat64 是 alias, 注入一处即可)
#     - my_mkdir    (新增, GOW->GOM)
#     - my_chdir    (新增, GOW->GOM)
#     - my_openat   (新增, GOW->GOM)
#     - my_bind     (新增, GOW->GOM, sockaddr_un 改写)
#     - my_connect  (新增, GOW->GOM, sockaddr_un 改写)
#
#   后续如果撞到 access/rename/symlink/readlink/realpath 等再加.
#
# 副作用:
#   guest 调 readlink("/proc/self/fd/N") 反向时拿到的是 host 真路径
#   (含 /data/storage/...). wine 不依赖反向比较, 暂时不修.
#
# 配置:
#   $TMPDIR 优先, 没有就用 /data/storage/el2/base/cache.
#   也可以通过 BOX64_TMP_TARGET 显式指定.
patch_65_path_remap() {
    local mark='OHOS_PATCH_PATH_REMAP'
    local f_remap="$BOX64/src/box64_path_remap.c"
    local f_libc="$BOX64/src/wrapped/wrappedlibc.c"
    local f_priv="$BOX64/src/wrapped/wrappedlibc_private.h"
    local f_cm="$BOX64/CMakeLists.txt"

    # ---- A) 创建 path remap 库 ----
    if [ -f "$f_remap" ] && grep -q "$mark" "$f_remap"; then
        _patch_header 65 "$f_remap" "remap lib — already"
    else
        _patch_header 65 "src/box64_path_remap.c" "create remap library"
        cat > "$f_remap" << 'EOF_REMAP'
/* OHOS_PATCH_PATH_REMAP
 *
 * proot-style 路径前缀改写. wine/wineserver 硬编码 /tmp 的部分在
 * HAP 沙箱里走不通, 这里在 box64 wrap 层做透明替换:
 *
 *   guest:  open("/tmp/.wine-1000/server-x-y/socket", ...)
 *   host:   open("/data/storage/el2/base/cache/box64-tmp/.wine-1000/server-x-y/socket", ...)
 *
 * 单向改写: 只改 guest -> host. wine 不做反向比较所以够用.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

struct path_map {
    const char* from;       /* 不带尾部 /, 例如 "/tmp" */
    size_t      from_len;
    const char* to;         /* 不带尾部 /, 例如 "/data/storage/.../box64-tmp" */
    size_t      to_len;
};

#define BOX64_REMAP_MAX 8
static struct path_map g_maps[BOX64_REMAP_MAX];
static int             g_nmaps = 0;
static int             g_inited = 0;
static pthread_mutex_t g_init_mu = PTHREAD_MUTEX_INITIALIZER;

/* mkdir -p 简化版 (一层一层建) */
static void box64_mkpath(const char* path) {
    if (!path || !*path) return;
    char buf[PATH_MAX];
    size_t n = strlen(path);
    if (n >= sizeof(buf)) return;
    memcpy(buf, path, n + 1);
    for (char* p = buf + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            mkdir(buf, 0700);   /* 失败无所谓 (可能已存在) */
            *p = '/';
        }
    }
    mkdir(buf, 0700);
}

static void box64_remap_init(void) {
    pthread_mutex_lock(&g_init_mu);
    if (g_inited) { pthread_mutex_unlock(&g_init_mu); return; }

    /* 解析 target 目录 */
    const char* override = getenv("BOX64_TMP_TARGET");
    const char* tmpdir   = getenv("TMPDIR");
    static char target[PATH_MAX];
    if (override && *override) {
        snprintf(target, sizeof(target), "%s", override);
    } else if (tmpdir && *tmpdir) {
        snprintf(target, sizeof(target), "%s/box64-tmp", tmpdir);
    } else {
        /* HAP 默认 fallback */
        snprintf(target, sizeof(target),
                 "/data/storage/el2/base/cache/box64-tmp");
    }
    /* trim 末尾 / */
    size_t tn = strlen(target);
    while (tn > 1 && target[tn - 1] == '/') target[--tn] = 0;

    box64_mkpath(target);
    if (access(target, W_OK) != 0) {
        fprintf(stderr,
            "[box64-remap] WARN: target dir '%s' not writable: %s\n",
            target, strerror(errno));
    } else {
        fprintf(stderr,
            "[box64-remap] /tmp -> %s\n", target);
    }

    g_maps[g_nmaps].from     = "/tmp";
    g_maps[g_nmaps].from_len = 4;
    g_maps[g_nmaps].to       = target;
    g_maps[g_nmaps].to_len   = tn;
    g_nmaps++;

    g_inited = 1;
    pthread_mutex_unlock(&g_init_mu);
}

__attribute__((constructor(120)))
static void box64_remap_ctor(void) { box64_remap_init(); }

/* 主入口: 命中改写到 buf 并返回 buf, 否则原样返回 path. */
__attribute__((visibility("default")))
const char* box64_remap_path(const char* path, char* buf, unsigned long buflen) {
    if (!path || !*path) return path;
    if (!g_inited) box64_remap_init();

    for (int i = 0; i < g_nmaps; i++) {
        const struct path_map* m = &g_maps[i];
        if (strncmp(path, m->from, m->from_len) != 0) continue;
        char tail = path[m->from_len];
        /* 边界: /tmp 完全相等, 或下一字符是 / 才算命中. 避免 /tmpfoo 被误改 */
        if (tail != '\0' && tail != '/') continue;

        size_t rest_len = strlen(path + m->from_len);
        size_t need = m->to_len + rest_len + 1;
        if (need > buflen) {
            /* buf 不够大, 兜底返回原路径 (调用方 fallback) */
            return path;
        }
        memcpy(buf, m->to, m->to_len);
        memcpy(buf + m->to_len, path + m->from_len, rest_len + 1);
        return buf;
    }
    return path;
}

/* 给 bind/connect 用的 sockaddr_un 改写.
 * 命中时把改写后的地址写到 *out_sa, 长度写到 *out_len, 返回 1.
 * 不命中或非 AF_UNIX 返回 0, 调用方使用原 sa.
 */
__attribute__((visibility("default")))
int box64_remap_sockaddr_un(const void* sa, unsigned int salen,
                            void* out_sa, unsigned int* out_len) {
    if (!sa || salen < sizeof(sa_family_t)) return 0;
    const struct sockaddr* p = (const struct sockaddr*)sa;
    if (p->sa_family != AF_UNIX) return 0;

    const struct sockaddr_un* sun_in = (const struct sockaddr_un*)sa;
    /* abstract socket (sun_path[0] == '\0') 不动 */
    if (salen < offsetof(struct sockaddr_un, sun_path) + 1) return 0;
    if (sun_in->sun_path[0] == '\0') return 0;

    /* sun_path 是定长数组, 不一定 NUL 终止. 算实际长度. */
    size_t maxp = sizeof(sun_in->sun_path);
    size_t plen = strnlen(sun_in->sun_path, maxp);
    char tmp[sizeof(sun_in->sun_path) + 1];
    if (plen >= sizeof(tmp)) return 0;
    memcpy(tmp, sun_in->sun_path, plen);
    tmp[plen] = '\0';

    char buf[PATH_MAX];
    const char* mapped = box64_remap_path(tmp, buf, sizeof(buf));
    if (mapped == tmp) return 0;   /* 没改写 */

    size_t mlen = strlen(mapped);
    if (mlen >= sizeof(sun_in->sun_path)) {
        fprintf(stderr,
            "[box64-remap] WARN: remapped sun_path too long (%zu >= %zu): %s\n",
            mlen, sizeof(sun_in->sun_path), mapped);
        return 0;
    }

    struct sockaddr_un* sun_out = (struct sockaddr_un*)out_sa;
    memset(sun_out, 0, sizeof(*sun_out));
    sun_out->sun_family = AF_UNIX;
    memcpy(sun_out->sun_path, mapped, mlen + 1);
    *out_len = (unsigned int)(offsetof(struct sockaddr_un, sun_path) + mlen + 1);
    return 1;
}
EOF_REMAP
    fi

    # ---- B) CMakeLists.txt 注册 ----
    if grep -q "${mark}_CM" "$f_cm"; then
        _patch_header 65 "CMakeLists.txt" "remap source — already"
    else
        cat >> "$f_cm" << EOF_CM
# ${mark}_CM ===================================
if(TARGET box64)
    target_sources(box64 PRIVATE \${CMAKE_SOURCE_DIR}/src/box64_path_remap.c)
endif()
# =============================================
EOF_CM
    fi

    # ---- C) wrappedlibc_private.h: GOW -> GOM 转 5 个 ----
    if grep -q "$mark" "$f_priv"; then
        _patch_header 65 "wrappedlibc_private.h" "GOW->GOM — already"
    else
        sed -i "1i\\
/* $mark */" "$f_priv"
        sed -i \
            -e 's|^GOW(bind, iFipu)|GOM(bind, iFEipu)|'         \
            -e 's|^GOW(chdir, iFp)|GOM(chdir, iFEp)|'           \
            -e 's|^GOW(connect, iFipu)|GOM(connect, iFEipu)|'   \
            -e 's|^GOW(mkdir, iFpu)|GOM(mkdir, iFEpu)|'         \
            -e 's|^GOW(openat, iFipON)|GOM(openat, iFEipON)|'   \
            "$f_priv"
        # 验证替换
        local need=5
        local got
        got=$(grep -cE '^GOM\((bind|chdir|connect|mkdir|openat),' "$f_priv")
        if [ "$got" -lt "$need" ]; then
            echo "    [#65] WARN: GOW->GOM 转换不完整 (got=$got, need=$need)"
        fi
    fi

    # ---- D) wrappedlibc.c: 注入 remap 到现有 my_open64/my_lstat ----
    if grep -q "$mark" "$f_libc"; then
        _patch_header 65 "wrappedlibc.c" "remap inject — already"
    else
        _patch_header 65 "wrappedlibc.c" "inject remap into my_open64/my_lstat + add new wrappers"
        sed -i "1i\\
/* $mark */\\
#include <limits.h>\\
extern const char* box64_remap_path(const char* path, char* buf, unsigned long buflen);\\
extern int box64_remap_sockaddr_un(const void* sa, unsigned int salen, void* out_sa, unsigned int* out_len);" "$f_libc"

        python3 - "$f_libc" << 'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()

# my_lstat injection
old_l = ('EXPORT int my_lstat(x64emu_t *emu, void* filename, void* buf)\n'
         '{\n'
         '    (void)emu;\n')
new_l = ('EXPORT int my_lstat(x64emu_t *emu, void* filename, void* buf)\n'
         '{\n'
         '    (void)emu;\n'
         '    /* OHOS_PATCH_PATH_REMAP */\n'
         '    char _remap_buf[PATH_MAX];\n'
         '    filename = (void*)box64_remap_path((const char*)filename, _remap_buf, sizeof(_remap_buf));\n')
if old_l not in s:
    print("ERROR: my_lstat injection target not matched", file=sys.stderr); sys.exit(1)
s = s.replace(old_l, new_l, 1)

# my_open64 injection
m = re.search(
    r'(EXPORT int32_t my_open64\(x64emu_t\* emu, void\* pathname, '
    r'int32_t flags, uint32_t mode\)\n\{\n)', s)
if not m:
    print("ERROR: my_open64 injection target not matched", file=sys.stderr); sys.exit(1)
inj = ('    /* OHOS_PATCH_PATH_REMAP */\n'
       '    char _remap_buf[PATH_MAX];\n'
       '    pathname = (void*)box64_remap_path((const char*)pathname, _remap_buf, sizeof(_remap_buf));\n')
s = s[:m.end()] + inj + s[m.end():]

open(p, 'w').write(s)
PY

        # 文件末尾追加新的 my_xxx 实现
        cat >> "$f_libc" << 'EOF_NEW_WRAPPERS'

/* OHOS_PATCH_PATH_REMAP — new wrappers added by patch 65
 * 这一组 GOW 在 patch 65 中升级到 GOM, 这里给出 my_xxx 实现.
 */
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <fcntl.h>

EXPORT int my_mkdir(x64emu_t* emu, void* path, uint32_t mode)
{
    (void)emu;
    char buf[PATH_MAX];
    path = (void*)box64_remap_path((const char*)path, buf, sizeof(buf));
    return mkdir((const char*)path, (mode_t)mode);
}

EXPORT int my_chdir(x64emu_t* emu, void* path)
{
    (void)emu;
    char buf[PATH_MAX];
    path = (void*)box64_remap_path((const char*)path, buf, sizeof(buf));
    return chdir((const char*)path);
}

EXPORT int my_openat(x64emu_t* emu, int dirfd, void* path, int flags, mode_t mode)
{
    (void)emu;
    char buf[PATH_MAX];
    path = (void*)box64_remap_path((const char*)path, buf, sizeof(buf));
    return openat(dirfd, (const char*)path, flags, mode);
}

EXPORT int my_bind(x64emu_t* emu, int sockfd, void* addr, uint32_t addrlen)
{
    (void)emu;
    struct sockaddr_un out;
    unsigned int out_len = 0;
    if (box64_remap_sockaddr_un(addr, addrlen, &out, &out_len) == 1) {
        return bind(sockfd, (struct sockaddr*)&out, (socklen_t)out_len);
    }
    return bind(sockfd, (struct sockaddr*)addr, (socklen_t)addrlen);
}

EXPORT int my_connect(x64emu_t* emu, int sockfd, void* addr, uint32_t addrlen)
{
    (void)emu;
    struct sockaddr_un out;
    unsigned int out_len = 0;
    if (box64_remap_sockaddr_un(addr, addrlen, &out, &out_len) == 1) {
        return connect(sockfd, (struct sockaddr*)&out, (socklen_t)out_len);
    }
    return connect(sockfd, (struct sockaddr*)addr, (socklen_t)addrlen);
}
/* OHOS_PATCH_PATH_REMAP END */
EOF_NEW_WRAPPERS
    fi
}

# ================================================================
# Patch 66 — path remap v2: WINEPREFIX/dosdevices + 第二波 wrappers
# ================================================================
# 现象:
#   wineboot --init 跑完 registry 阶段 (system.reg/user.reg 已生成),
#   wine 主进程 try load kernel32.dll, 解析 NT 路径 C:\windows\system32\
#   kernel32.dll 时调用:
#     opendir("/.../wineprefix/dosdevices/c:") -> ENOENT
#   退出 STATUS_DLL_NOT_FOUND (0xC0000135).
#
# 根因:
#   wine 在 Linux 上把 dosdevices/c: 做成 symlink 指向 ../drive_c.
#   HAP 沙箱拒绝 symlink syscall, wineboot 静默失败, dosdevices/c: 不存在,
#   后续所有"C: 盘"路径解析全部 ENOENT, fakedll 也装不进 system32.
#
# 修法 (proot 第二波):
#   1) box64_path_remap.c 加动态规则:
#      ${WINEPREFIX}/dosdevices/c:  ->  ${WINEPREFIX}/drive_c
#      WINEPREFIX 在 box64_run 启动时通过 environ 进来, ctor 跑得早可能
#      还没设, 因此用 lazy add (每次调 remap 时检查).
#   2) 第二波 wrap (GOW/GO -> GOM): opendir / access / faccessat /
#      unlink / rmdir / rename / symlink / symlinkat
#   3) 已有 my_xxx 实现的注入: my_stat / my_fstatat / my_readlink /
#      my_realpath
#   4) symlink / symlinkat 在 HAP 直接禁, 我们 fake 成功返回 0
#      (依赖 path remap 让后续访问通过, 不依赖真 symlink 存在)
#
# 副作用:
#   - readlink("/.../dosdevices/c:") 仍会返回 EINVAL (host 上不是 link).
#     wine 实测对此不敏感, 失败后走 stat fallback, stat 命中 remap 通过.
#   - rename 用了两个 PATH_MAX 栈缓冲 (~8KB), 在 wine 栈预算内.
#
# 不在本 patch 内的:
#   - dosdevices/d:..z: 等其它盘符. 当前 wineprefix 只用 c:, 后续按需扩.
#   - readlinkat / __readlinkat_chk / __readlink_chk 注入. 撞到再加.
# ================================================================
# Patch 66 — path remap v2: WINEPREFIX/dosdevices + 第二波 wrappers
# ================================================================
# (头部说明同前略, 关键修订:)
#   - python inject 同时做 3 件事: 加前置声明 + 加 hook 调用 + 添加 mark
#   - 防止 box64_remap_path 调用 box64_remap_maybe_add_wineprefix_rule
#     时无声明 → implicit int (*)() 与后置 void 定义冲突
patch_66_path_remap_v2() {
    local mark='OHOS_PATCH_PATH_REMAP_V2'
    local f_remap="$BOX64/src/box64_path_remap.c"
    local f_libc="$BOX64/src/wrapped/wrappedlibc.c"
    local f_priv="$BOX64/src/wrapped/wrappedlibc_private.h"

    # ---- A) box64_path_remap.c: 加 WINEPREFIX 动态规则 ----
    if [ -f "$f_remap" ] && grep -q "$mark" "$f_remap"; then
        _patch_header 66 "src/box64_path_remap.c" "v2 — already"
    else
        _patch_header 66 "src/box64_path_remap.c" "add lazy WINEPREFIX dosdevices/c: rule"

        # 1) 末尾追加函数定义 (cat >>)
        cat >> "$f_remap" << 'EOF_V2'

/* OHOS_PATCH_PATH_REMAP_V2
 * lazy 加 ${WINEPREFIX}/dosdevices/c: -> ${WINEPREFIX}/drive_c.
 * WINEPREFIX 在 box64_run 启动期通过 environ 传入, ctor 跑得太早拿不到.
 * 这里在每次 box64_remap_path 入口检查, 一旦 getenv 命中就建规则.
 */
static int g_wineprefix_done = 0;
static char g_wp_from[PATH_MAX];
static char g_wp_to  [PATH_MAX];

void box64_remap_maybe_add_wineprefix_rule(void) {
    if (__atomic_load_n(&g_wineprefix_done, __ATOMIC_ACQUIRE)) return;

    pthread_mutex_lock(&g_init_mu);
    if (g_wineprefix_done) { pthread_mutex_unlock(&g_init_mu); return; }

    const char* wp = getenv("WINEPREFIX");
    if (!wp || !*wp) {
        /* 环境变量还没就位, 这次不算"已尝试", 下次再 try */
        pthread_mutex_unlock(&g_init_mu);
        return;
    }

    /* trim trailing / */
    size_t wpl = strlen(wp);
    while (wpl > 1 && wp[wpl - 1] == '/') wpl--;

    int n = snprintf(g_wp_from, sizeof(g_wp_from),
                     "%.*s/dosdevices/c:", (int)wpl, wp);
    int m = snprintf(g_wp_to,   sizeof(g_wp_to),
                     "%.*s/drive_c",       (int)wpl, wp);

    if (n > 0 && (size_t)n < sizeof(g_wp_from) &&
        m > 0 && (size_t)m < sizeof(g_wp_to)   &&
        g_nmaps < BOX64_REMAP_MAX) {
        g_maps[g_nmaps].from     = g_wp_from;
        g_maps[g_nmaps].from_len = (size_t)n;
        g_maps[g_nmaps].to       = g_wp_to;
        g_maps[g_nmaps].to_len   = (size_t)m;
        g_nmaps++;
        fprintf(stderr, "[box64-remap] %s -> %s\n", g_wp_from, g_wp_to);
    }

    __atomic_store_n(&g_wineprefix_done, 1, __ATOMIC_RELEASE);
    pthread_mutex_unlock(&g_init_mu);
}
EOF_V2

        # 2) python 一次完成: 前置声明 + hook 调用注入
        python3 - "$f_remap" << 'PY'
import sys
p = sys.argv[1]
s = open(p).read()

# (a) 前置声明 — 必须在 box64_remap_path 之前. 不能走 cat >> 路径,
#     因为 cat >> 是追加到末尾, 此时 box64_remap_path 调用它时 C 编译器
#     已经隐式生成了 int (*)() 的声明, 与后面 void 定义冲突.
fwd_decl = 'void box64_remap_maybe_add_wineprefix_rule(void);\n'
anchor   = 'const char* box64_remap_path(const char* path, char* buf, unsigned long buflen) {\n'
if anchor not in s:
    print("ERROR: box64_remap_path anchor not matched", file=sys.stderr); sys.exit(1)
if fwd_decl not in s:
    s = s.replace(anchor, fwd_decl + '\n' + anchor, 1)

# (b) hook 调用注入到 box64_remap_path 入口
old = ('const char* box64_remap_path(const char* path, char* buf, unsigned long buflen) {\n'
       '    if (!path || !*path) return path;\n'
       '    if (!g_inited) box64_remap_init();\n')
new = ('const char* box64_remap_path(const char* path, char* buf, unsigned long buflen) {\n'
       '    if (!path || !*path) return path;\n'
       '    if (!g_inited) box64_remap_init();\n'
       '    /* OHOS_PATCH_PATH_REMAP_V2_HOOK */\n'
       '    box64_remap_maybe_add_wineprefix_rule();\n')
if old not in s:
    print("ERROR: remap_path hook target not matched", file=sys.stderr); sys.exit(1)
s = s.replace(old, new, 1)

open(p, 'w').write(s)
print("  patch_66: forward decl + WINEPREFIX lazy hook injected")
PY
    fi

    # ---- B) wrappedlibc_private.h: 第二批 GOW/GO -> GOM (8 个) ----
    if grep -q "$mark" "$f_priv"; then
        _patch_header 66 "wrappedlibc_private.h" "v2 GOW->GOM — already"
    else
        sed -i "1i\\
/* $mark */" "$f_priv"
        sed -i \
            -e 's|^GOW(opendir, pFp)|GOM(opendir, pFEp)|'              \
            -e 's|^GOW(access, iFpi)|GOM(access, iFEpi)|'              \
            -e 's|^GO(faccessat, iFipii)|GOM(faccessat, iFEipii)|'     \
            -e 's|^GOW(unlink, iFp)|GOM(unlink, iFEp)|'                \
            -e 's|^GOW(rmdir, iFp)|GOM(rmdir, iFEp)|'                  \
            -e 's|^GO(rename, iFpp)|GOM(rename, iFEpp)|'               \
            -e 's|^GOW(symlink, iFpp)|GOM(symlink, iFEpp)|'            \
            -e 's|^GO(symlinkat, iFpip)|GOM(symlinkat, iFEpip)|'       \
            "$f_priv"
        local got
        got=$(grep -cE '^GOM\((opendir|access|faccessat|unlink|rmdir|rename|symlink|symlinkat),' "$f_priv")
        if [ "$got" -lt 8 ]; then
            echo "    [#66] WARN: GOW/GO->GOM 转换不全 (got=$got, need=8)"
        fi
    fi

    # ---- C) wrappedlibc.c: 注入 + 末尾追加新 wrappers ----
    if grep -q "$mark" "$f_libc"; then
        _patch_header 66 "wrappedlibc.c" "v2 inject — already"
    else
        _patch_header 66 "wrappedlibc.c" "inject 4 + add 8 wrappers"
        sed -i "1i\\
/* $mark */\\
extern void box64_remap_maybe_add_wineprefix_rule(void);" "$f_libc"

        python3 - "$f_libc" << 'PY'
import sys
p = sys.argv[1]
s = open(p).read()

def inject(s, target_text, inj):
    if target_text not in s:
        print(f"ERROR: inject target not matched: {target_text[:80]!r}", file=sys.stderr)
        sys.exit(1)
    return s.replace(target_text, target_text + inj, 1)

# 1) my_stat
s = inject(s,
    'EXPORT int my_stat(x64emu_t *emu, void* filename, void* buf)\n'
    '{\n'
    '    (void)emu;\n',
    '    /* OHOS_PATCH_PATH_REMAP_V2 */\n'
    '    char _remap_buf_stat[PATH_MAX];\n'
    '    filename = (void*)box64_remap_path((const char*)filename, _remap_buf_stat, sizeof(_remap_buf_stat));\n')

# 2) my_fstatat
s = inject(s,
    'EXPORT int my_fstatat(x64emu_t *emu, int fd, const char* path, void* buf, int flags)\n'
    '{\n',
    '    /* OHOS_PATCH_PATH_REMAP_V2 */\n'
    '    char _remap_buf_fstatat[PATH_MAX];\n'
    '    path = box64_remap_path(path, _remap_buf_fstatat, sizeof(_remap_buf_fstatat));\n')

# 3) my_readlink
s = inject(s,
    'EXPORT ssize_t my_readlink(x64emu_t* emu, void* path, void* buf, size_t sz)\n'
    '{\n',
    '    /* OHOS_PATCH_PATH_REMAP_V2 */\n'
    '    char _remap_buf_rl[PATH_MAX];\n'
    '    path = (void*)box64_remap_path((const char*)path, _remap_buf_rl, sizeof(_remap_buf_rl));\n')

# 4) my_realpath
s = inject(s,
    'EXPORT void* my_realpath(x64emu_t* emu, void* path, void* resolved_path)\n'
    '{\n',
    '    /* OHOS_PATCH_PATH_REMAP_V2 */\n'
    '    char _remap_buf_rp[PATH_MAX];\n'
    '    path = (void*)box64_remap_path((const char*)path, _remap_buf_rp, sizeof(_remap_buf_rp));\n')

open(p, 'w').write(s)
PY

        cat >> "$f_libc" << 'EOF_NEW_V2'

/* OHOS_PATCH_PATH_REMAP_V2 — new wrappers (path remap second wave). */
#include <dirent.h>

EXPORT void* my_opendir(x64emu_t* emu, void* path)
{
    (void)emu;
    char buf[PATH_MAX];
    path = (void*)box64_remap_path((const char*)path, buf, sizeof(buf));
    return opendir((const char*)path);
}

EXPORT int my_access(x64emu_t* emu, void* path, int mode)
{
    (void)emu;
    char buf[PATH_MAX];
    path = (void*)box64_remap_path((const char*)path, buf, sizeof(buf));
    return access((const char*)path, mode);
}

EXPORT int my_faccessat(x64emu_t* emu, int dirfd, void* path, int mode, int flags)
{
    (void)emu;
    char buf[PATH_MAX];
    path = (void*)box64_remap_path((const char*)path, buf, sizeof(buf));
    return faccessat(dirfd, (const char*)path, mode, flags);
}

EXPORT int my_unlink(x64emu_t* emu, void* path)
{
    (void)emu;
    char buf[PATH_MAX];
    path = (void*)box64_remap_path((const char*)path, buf, sizeof(buf));
    return unlink((const char*)path);
}

EXPORT int my_rmdir(x64emu_t* emu, void* path)
{
    (void)emu;
    char buf[PATH_MAX];
    path = (void*)box64_remap_path((const char*)path, buf, sizeof(buf));
    return rmdir((const char*)path);
}

EXPORT int my_rename(x64emu_t* emu, void* oldpath, void* newpath)
{
    (void)emu;
    char buf1[PATH_MAX], buf2[PATH_MAX];
    oldpath = (void*)box64_remap_path((const char*)oldpath, buf1, sizeof(buf1));
    newpath = (void*)box64_remap_path((const char*)newpath, buf2, sizeof(buf2));
    return rename((const char*)oldpath, (const char*)newpath);
}

/* HAP 沙箱禁 symlink syscall. fake 返回 0:
 *   - 配合 path remap, 后续 stat/open 命中真实目录 -> 透明
 *   - 副作用: lstat 这个 link 会拿到 ENOENT, 真依赖此行为的代码会跑偏
 *   - 当前 wineboot 路径 (dosdevices/c:) 完全靠 path remap 解决, 不依赖
 *     真 symlink 存在
 */
EXPORT int my_symlink(x64emu_t* emu, void* target, void* linkpath)
{
    (void)emu;
    fprintf(stderr, "[box64-remap] symlink('%s', '%s') -> faked OK (HAP)\n",
            target   ? (const char*)target   : "(null)",
            linkpath ? (const char*)linkpath : "(null)");
    return 0;
}

EXPORT int my_symlinkat(x64emu_t* emu, void* target, int newdirfd, void* linkpath)
{
    (void)emu;
    fprintf(stderr, "[box64-remap] symlinkat('%s', %d, '%s') -> faked OK\n",
            target   ? (const char*)target   : "(null)", newdirfd,
            linkpath ? (const char*)linkpath : "(null)");
    return 0;
}
/* OHOS_PATCH_PATH_REMAP_V2 END */
EOF_NEW_V2
    fi
}

# Patch 67 — 补齐 my_open + 关键 wrappers 的 remap
patch_67_path_remap_v3_missing_wrappers() {
    local mark='OHOS_PATCH_PATH_REMAP_V3'
    local f_libc="$BOX64/src/wrapped/wrappedlibc.c"

    [ -f "$f_libc" ] || { _patch_header 67 "(skip) wrappedlibc.c not found" ""; return 0; }
    if _already "$f_libc" "$mark"; then
        _patch_header 67 "wrappedlibc.c" "v3 my_open remap — already"
        return 0
    fi
    _patch_header 67 "wrappedlibc.c" "fix: inject remap into my_open (was only in my_open64)"

    python3 - "$f_libc" "$mark" << 'PY'
import sys, re
p, mark = sys.argv[1], sys.argv[2]
s = open(p).read()
if mark in s:
    sys.exit(0)

# my_open 的标准签名: EXPORT int32_t my_open(x64emu_t* emu, void* pathname, int32_t flags, uint32_t mode)
# 注意: 不同 box64 版本可能用 int 或 int32_t, 用宽松匹配.
patterns = [
    re.compile(
        r'(EXPORT\s+int(?:32_t)?\s+my_open\s*\(\s*x64emu_t\s*\*\s*emu\s*,\s*'
        r'void\s*\*\s*pathname\s*,\s*int(?:32_t)?\s+flags\s*,\s*'
        r'uint?32?_?t?\s+mode\s*\)\s*\n\{\s*\n)'),
]

inj = ('    /* %s */\n'
       '    char _remap_buf_open[PATH_MAX];\n'
       '    pathname = (void*)box64_remap_path((const char*)pathname, _remap_buf_open, sizeof(_remap_buf_open));\n'
       % mark)

found = False
for pat in patterns:
    m = pat.search(s)
    if m:
        s = s[:m.end()] + inj + s[m.end():]
        found = True
        break

if not found:
    # 兜底: 找 'EXPORT' + 'my_open(' 但不是 my_openat/my_open64
    pat = re.compile(r'(EXPORT[^\n]*\bmy_open\b(?!at|64)[^{]*\{\s*\n)')
    m = pat.search(s)
    if m:
        s = s[:m.end()] + inj + s[m.end():]
        found = True

if not found:
    print("ERROR: my_open signature not matched (manual check needed)",
          file=sys.stderr)
    sys.exit(1)

# 顺便加 mark 标签到顶部, 方便 grep
header = "/* %s */\n" % mark
if header not in s:
    s = header + s

open(p, 'w').write(s)
PY
}

# Patch 68 — Path remap 诊断 (BOX64_REMAP_TRACE)
patch_68_path_remap_trace() {
    local mark='OHOS_PATCH_PATH_REMAP_TRACE'
    local f="$BOX64/src/box64_path_remap.c"

    [ -f "$f" ] || { _patch_header 68 "(skip) box64_path_remap.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 68 "box64_path_remap.c" "trace — already"
        return 0
    fi
    _patch_header 68 "box64_path_remap.c" "add BOX64_REMAP_TRACE=1 detailed logging"

    python3 - "$f" "$mark" << 'PY'
import sys
p, mark = sys.argv[1], sys.argv[2]
s = open(p).read()
if mark in s:
    sys.exit(0)

# 注入 trace helper 在 box64_remap_path 之前
helper = '''
/* %s */
static int ohos_remap_trace_level(void) {
    static int cached = -1;
    if (cached < 0) {
        const char* v = getenv("BOX64_REMAP_TRACE");
        cached = (v && *v) ? atoi(v) : 0;
        if (cached < 0) cached = 0;
    }
    return cached;
}
/* 只 trace 包含这些关键串的路径, 避免刷屏 */
static int ohos_remap_should_trace(const char* path) {
    if (!path) return 0;
    if (ohos_remap_trace_level() >= 2) return 1;   /* level 2 = 全量 */
    /* level 1 = 只看 wine 关键路径 */
    return (strstr(path, "dosdevices")     != NULL ||
            strstr(path, "/tmp")           != NULL ||
            strstr(path, "wineboot")       != NULL ||
            strstr(path, "system32")       != NULL ||
            strstr(path, "wine-")          != NULL);
}
''' % mark

anchor = 'const char* box64_remap_path(const char* path, char* buf, unsigned long buflen) {\n'
if anchor not in s:
    print("ERROR: anchor missing", file=sys.stderr); sys.exit(1)
s = s.replace(anchor, helper + '\n' + anchor, 1)

# 在 box64_remap_path 主循环出口加 trace
# 命中分支末尾的 return buf:
old_hit = ('        memcpy(buf, m->to, m->to_len);\n'
           '        memcpy(buf + m->to_len, path + m->from_len, rest_len + 1);\n'
           '        return buf;\n')
new_hit = ('        memcpy(buf, m->to, m->to_len);\n'
           '        memcpy(buf + m->to_len, path + m->from_len, rest_len + 1);\n'
           '        if (ohos_remap_should_trace(path)) {\n'
           '            fprintf(stderr, "[remap-trace] HIT  %s -> %s\\n", path, buf);\n'
           '            fflush(stderr);\n'
           '        }\n'
           '        return buf;\n')
if old_hit not in s:
    print("WARN: HIT branch not matched (skip)", file=sys.stderr)
else:
    s = s.replace(old_hit, new_hit, 1)

# 未命中分支末尾 return path:
old_miss = '    return path;\n}\n\n/* 给 bind/connect 用的 sockaddr_un 改写'
new_miss = ('    if (ohos_remap_should_trace(path)) {\n'
            '        fprintf(stderr, "[remap-trace] MISS %s (nmaps=%d)\\n", path, g_nmaps);\n'
            '        fflush(stderr);\n'
            '    }\n'
            '    return path;\n}\n\n/* 给 bind/connect 用的 sockaddr_un 改写')
if old_miss in s:
    s = s.replace(old_miss, new_miss, 1)
else:
    print("WARN: MISS branch not matched (skip)", file=sys.stderr)

open(p, 'w').write(s)
PY
}

# ================================================================
# Patch 72 — patch 62 fallback 按 prot 分场景 + 加 trace
# ================================================================
# 现象 (patch 70/71 之后的最后一公里):
#   patch 70 清掉父继承 reserve, patch 71 在 child 重做 4 段 PROT_NONE
#   reserve, 把 0x7ffe0000 (KUSER_SHARED_DATA) 留成单独 4KB hole.
#
#   wine ntdll 调:
#       mmap(0x7ffe0000, 4096, PROT_READ,
#            MAP_FIXED_NOREPLACE|MAP_PRIVATE|MAP_ANON, -1, 0)
#   HAP seccomp 拒 NOREPLACE -> ENOSYS, patch 62 fallback 把 NOREPLACE
#   去掉, 用 hint mmap. kernel hint 算法因为 0x7ffe0000 被两段 PROT_NONE
#   紧紧夹住, 拒绝 hint, 返回别处. patch 62 判 ret != addr -> munmap +
#   EEXIST. wine 收 EEXIST 报 STATUS_CONFLICTING_ADDRESSES (c0000018).
#
# 修法 (区分 wine 用 NOREPLACE 的两种语义):
#   prot == 0 (探测): 保持原 hint 模式. wine 早期探测 4GB / 64GB / 2^63
#                     等边界, 占用就 EEXIST, wine 会换地址.
#   prot != 0 (真分配): fallback 用 MAP_FIXED 强制放到 addr.
#                       wine 此时是要确定地址 (KUSER_SHARED_DATA / TEB),
#                       hint 模式不可靠. FIXED 会覆盖现有 mapping, 但
#                       这种"现有 mapping"通常是我们 reserve 的 PROT_NONE
#                       hole, 覆盖它正是 wine 的目的.
#
# 同时加详细 trace, 后续排错可见:
#   [mmap-noreplace] addr=0x7ffe0000 len=4096 prot=1 flags=0x100022
#   [mmap-noreplace]   fallback FIXED -> 0x7ffe0000 errno=0  (real-alloc)
#   [mmap-noreplace]   fallback HINT  -> 0x... errno=0 (probe, munmap+EEXIST)
patch_72_mmap_noreplace_split() {
    local f="$BOX64/src/wrapped/wrappedlibc.c"
    local mark='OHOS_PATCH_MMAP_NOREPLACE_V2'

    [ -f "$f" ] || { _patch_header 72 "(skip) wrappedlibc.c not found" ""; return 0; }
    if grep -q "$mark" "$f"; then
        _patch_header 72 "src/wrapped/wrappedlibc.c" "v2 fallback — already"
        return 0
    fi
    if ! grep -q 'OHOS_PATCH_MMAP_NOREPLACE_FALLBACK' "$f"; then
        _patch_header 72 "(skip) patch 62 not applied yet" ""
        return 0
    fi
    _patch_header 72 "src/wrapped/wrappedlibc.c" \
        "split NOREPLACE fallback by prot, add diagnostic trace"

    python3 - "$f" << 'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()

if 'OHOS_PATCH_MMAP_NOREPLACE_V2' in s:
    sys.exit(0)

# 替换 patch 62 整个 fallback 块
old_marker_start = '/* OHOS_PATCH_MMAP_NOREPLACE_FALLBACK START'
old_marker_end   = '/* OHOS_PATCH_MMAP_NOREPLACE_FALLBACK END */'

i0 = s.find(old_marker_start)
i1 = s.find(old_marker_end)
if i0 < 0 or i1 < 0:
    print("FATAL: cannot locate patch 62 fallback block", file=sys.stderr)
    sys.exit(1)
i1 += len(old_marker_end)

new_block = '''/* OHOS_PATCH_MMAP_NOREPLACE_V2 START
 * 替代 patch 62. HAP seccomp 拒 MAP_FIXED_NOREPLACE 用 ENOSYS, 退化策略
 * 按 prot 分场景:
 *   - prot == 0 (探测): 用 hint mmap, ret != addr 时 munmap + EEXIST.
 *     wine 用这种调用试地址边界, 我们告诉它"占了"它会换.
 *   - prot != 0 (真分配): 直接用 MAP_FIXED 强制 addr.
 *     wine 此时要确定地址 (KUSER_SHARED_DATA/TEB), hint 不可靠.
 */
#ifndef BOX64_OHOS_MAP_FIXED_NOREPLACE
#define BOX64_OHOS_MAP_FIXED_NOREPLACE 0x100000
#endif
void* ret = box_mmap(addr, length, prot, flags, fd, offset);
int e = errno;
if (ret == MAP_FAILED && (e == ENOSYS || e == EINVAL)
    && (flags & BOX64_OHOS_MAP_FIXED_NOREPLACE)
    && !(flags & MAP_FIXED) && addr) {
    int probe = (prot == 0);
    int fb_flags = flags & ~BOX64_OHOS_MAP_FIXED_NOREPLACE;
    if (!probe) fb_flags |= MAP_FIXED;
    void* fb_ret = box_mmap(addr, length, prot, fb_flags, fd, offset);
    int fb_e = errno;
    fprintf(stderr,
        "[mmap-noreplace] addr=%p len=0x%lx prot=0x%x flags=0x%x "
        "%s -> %p errno=%d\\n",
        addr, (unsigned long)length, prot, flags,
        probe ? "probe(HINT)" : "real(FIXED)",
        fb_ret, fb_ret == MAP_FAILED ? fb_e : 0);
    if (probe) {
        if (fb_ret != MAP_FAILED && (uintptr_t)fb_ret != (uintptr_t)addr) {
            /* 探测模式: kernel 不给 hint -> 模拟 NOREPLACE 失败 */
            box_munmap(fb_ret, length);
            ret = MAP_FAILED;
            e = EEXIST;
        } else {
            ret = fb_ret;
            e = (fb_ret == MAP_FAILED) ? fb_e : 0;
        }
    } else {
        /* 真分配: MAP_FIXED 要么成功拿到 addr 要么真失败, 不再判 conflict */
        ret = fb_ret;
        e = (fb_ret == MAP_FAILED) ? fb_e : 0;
    }
    errno = e;
}
/* OHOS_PATCH_MMAP_NOREPLACE_V2 END */'''

s = s[:i0] + new_block + s[i1:]
open(p, 'w').write(s)
PY
}

# ================================================================
# Patch 80 — src/box64_spawn.c: 三态 spawn 策略 (NATIVE/FORK/SOCK)
# ================================================================
# 目的:
#   box64 在 OHOS HAP 内以 .so 形式存在, wine 等 guest 程序会尝试
#   execve/posix_spawn 一个新 box64 进程跑 wineserver/wineboot.
#   磁盘上没有 box64 二进制, 直通 execve 必然 ENOENT.
#
# 三种策略 (BOX64_SPAWN_STRATEGY 环境变量):
#   native  直通 execve / posix_spawn  (仅 hnp 模式有真 box64 二进制时可用)
#   fork    fork + box64_run           (老沙箱可用, 不需要 HAP 主进程协助)
#   sock    通过 control socket 让 HAP 主进程代为 spawn   (默认)
#
# 自动降级:
#   sock 模式连接 / 通信失败 -> 自动降级到 fork. 通过 s_sock_broken
#   静态标志记忆, 单次失败后整个进程不再尝试 sock, 避免反复重连.
#
# socket 协议 (与 process_manager.cpp 镜像):
#   帧: [4 字节大端长度] + [文本 payload]
#   请求 CMD CREATE / REQ_ID / EXE / ARG / ENV / CWD / KIND / WAIT / END
#   响应 RESULT / REQ_ID / STATUS / PID / KIND / EXIT_CODE / MSG / END
#   WAIT=1 + STATUS=ok 时响应带 EXIT_CODE.
#
# 内存清理 (仅 FORK 路径需要):
#   子进程继承父进程 wine prereserve, 子 box64 init 又自己 reserve 一次
#   会撞 0x7ffe0000 (KUSER_SHARED_DATA) 那个 4KB hole. 处理顺序:
#     1) munmap 4 段父继承的 reserve (low-stub/low-heap/pre-kuser/post-kuser)
#     2) 用 PROT_NONE FIXED 自己 reserve 这 4 段
#   NATIVE 不需要 (execve 自动 image replace).
#   SOCK 不需要 (新进程是 HAP 主进程的孩子, 干净 mapping).
patch_80_box64_spawn() {
    local f="$BOX64/src/box64_spawn.c"
    local cm="$BOX64/CMakeLists.txt"
    local mark='OHOS_PATCH_BOX64_SPAWN'

    if [ -f "$f" ] && grep -q "$mark" "$f"; then
        _patch_header 80 "src/box64_spawn.c" "spawn dispatcher — already patched"
        return 0
    fi
    _patch_header 80 "src/box64_spawn.c" "create three-strategy spawn dispatcher"

    cat > "$f" << 'EOF_SPAWN'
/* OHOS_PATCH_BOX64_SPAWN
 *
 * Three-strategy spawn dispatcher for OHOS HAP environment.
 *
 * Strategy chosen by env BOX64_SPAWN_STRATEGY:
 *   native  - direct execve / posix_spawn (only valid in hnp mode)
 *   fork    - fork + box64_run (self-recursion)
 *   sock    - delegate to HAP main process via control socket (default)
 *
 * Auto fallback: sock failure -> fork. Marked sticky in s_sock_broken.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

extern char** environ;
extern int box64_run(int argc, const char** argv, const char** env);

/* ================================================================
 * [1] strategy config
 * ================================================================ */
enum spawn_strategy { SP_NATIVE = 0, SP_FORK = 1, SP_SOCK = 2 };
static int s_strategy    = -1;
static int s_sock_broken = 0;

static const char* DEFAULT_SOCK_PATH =
    "/data/storage/el2/base/haps/entry/files/.procmgr.sock";

static enum spawn_strategy get_strategy(void) {
    if (s_strategy != -1) return (enum spawn_strategy)s_strategy;
    const char* v = getenv("BOX64_SPAWN_STRATEGY");
    enum spawn_strategy s;
    if      (!v || !*v)            s = SP_SOCK;
    else if (!strcmp(v, "native")) s = SP_NATIVE;
    else if (!strcmp(v, "fork"))   s = SP_FORK;
    else if (!strcmp(v, "sock"))   s = SP_SOCK;
    else                           s = SP_SOCK;
    s_strategy = (int)s;
    fprintf(stderr, "[box64-spawn] strategy=%s\n",
        s == SP_NATIVE ? "native" : s == SP_FORK ? "fork" : "sock");
    return s;
}

static const char* get_sock_path(void) {
    const char* v = getenv("BOX64_PROCMGR_SOCK");
    return (v && *v) ? v : DEFAULT_SOCK_PATH;
}

static int count_argv(char* const argv[]) {
    int n = 0;
    if (!argv) return 0;
    while (argv[n]) n++;
    return n;
}

/* ================================================================
 * [2] socket client (used by sock strategy)
 * ================================================================ */
static int sock_write_all(int fd, const void* p, size_t n) {
    const uint8_t* b = (const uint8_t*)p;
    while (n) {
        ssize_t w = send(fd, b, n, MSG_NOSIGNAL);
        if (w <= 0) { if (w < 0 && errno == EINTR) continue; return -1; }
        b += w; n -= (size_t)w;
    }
    return 0;
}
static int sock_read_all(int fd, void* p, size_t n) {
    uint8_t* b = (uint8_t*)p;
    while (n) {
        ssize_t r = recv(fd, b, n, 0);
        if (r <= 0) { if (r < 0 && errno == EINTR) continue; return -1; }
        b += r; n -= (size_t)r;
    }
    return 0;
}
static int frame_write(int fd, const char* p, size_t n) {
    uint8_t h[4] = {
        (uint8_t)(n >> 24), (uint8_t)(n >> 16),
        (uint8_t)(n >>  8), (uint8_t) n
    };
    if (sock_write_all(fd, h, 4) < 0) return -1;
    return sock_write_all(fd, p, n);
}

static int frame_read(int fd, char* buf, size_t cap, size_t* out_len) {
    uint8_t h[4];
    if (sock_read_all(fd, h, 4) < 0) return -1;
    size_t n = ((size_t)h[0]<<24)|((size_t)h[1]<<16)
             | ((size_t)h[2]<< 8)|(size_t)h[3];
    if (n >= cap) return -1;
    if (sock_read_all(fd, buf, n) < 0) return -1;
    buf[n] = 0;
    if (out_len) *out_len = n;
    return 0;
}

static int sock_connect(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", get_sock_path());
    if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        int e = errno;
        close(fd);
        errno = e;
        return -1;
    }
    return fd;
}

/* Append "KEY value\n" to *buf. *off / cap protected. */
static int buf_appendf(char* buf, size_t cap, size_t* off,
                       const char* fmt, ...) {
    if (*off >= cap) return -1;
    va_list ap; va_start(ap, fmt);
    int n = vsnprintf(buf + *off, cap - *off, fmt, ap);
    va_end(ap);
    if (n < 0 || (size_t)n >= cap - *off) return -1;
    *off += (size_t)n;
    return 0;
}

/* Build CMD CREATE payload. Returns length, or -1 on overflow. */
static int build_create_req(char* buf, size_t cap,
                            const char* exe,
                            char* const argv[], char* const envp[],
                            int wait_flag) {
    size_t off = 0;
    if (buf_appendf(buf, cap, &off, "CMD CREATE\n")             < 0) return -1;
    if (buf_appendf(buf, cap, &off, "REQ_ID 1\n")               < 0) return -1;
    if (buf_appendf(buf, cap, &off, "EXE %s\n", exe ? exe : "") < 0) return -1;
    if (buf_appendf(buf, cap, &off, "KIND box64\n")             < 0) return -1;
    if (buf_appendf(buf, cap, &off, "WAIT %d\n", wait_flag)     < 0) return -1;
    if (argv) {
        for (int i = 0; argv[i]; i++) {
            if (buf_appendf(buf, cap, &off, "ARG %s\n", argv[i]) < 0) return -1;
        }
    }
    if (envp) {
        for (int i = 0; envp[i]; i++) {
            if (buf_appendf(buf, cap, &off, "ENV %s\n", envp[i]) < 0) return -1;
        }
    }
    if (buf_appendf(buf, cap, &off, "END") < 0) return -1;
    return (int)off;
}

/* Parse RESULT response. status_ok: 1=ok, 0=error. */
static int parse_create_resp(const char* p, size_t n,
                             int* status_ok, pid_t* out_pid,
                             int* out_exit_code, char* msg, size_t msg_cap) {
    *status_ok = 0;
    if (out_pid)       *out_pid = -1;
    if (out_exit_code) *out_exit_code = -1;
    if (msg && msg_cap) msg[0] = 0;

    size_t i = 0;
    while (i < n) {
        size_t j = i;
        while (j < n && p[j] != '\n') j++;
        size_t llen = j - i;
        const char* line = p + i;

        if      (llen == 9 && !strncmp(line, "STATUS ok", 9))    *status_ok = 1;
        else if (llen >= 4 && !strncmp(line, "PID ", 4) && out_pid) {
            *out_pid = (pid_t)atol(line + 4);
        }
        else if (llen >= 10 && !strncmp(line, "EXIT_CODE ", 10) && out_exit_code) {
            *out_exit_code = atoi(line + 10);
        }
        else if (llen >= 4 && !strncmp(line, "MSG ", 4) && msg && msg_cap) {
            size_t cp = llen - 4;
            if (cp >= msg_cap) cp = msg_cap - 1;
            memcpy(msg, line + 4, cp);
            msg[cp] = 0;
        }
        else if (llen == 3 && !strncmp(line, "END", 3)) {
            return 0;
        }
        i = j + 1;
    }
    return 0;
}

/* ================================================================
 * [3] FORK: child wine prereserve cleanup
 * ================================================================ */
struct unmap_region { unsigned long base; unsigned long size; const char* name; };
static const struct unmap_region s_wine_reserve[] = {
    { 0x00010000UL, 0x00008000UL,    "low-stub" },
    { 0x00110000UL, 0x30000000UL,    "low-heap" },
    { 0x7f000000UL, 0x00fe0000UL,    "high-pre-kuser" },
    { 0x7ffe1000UL, 0x0201f000UL,    "high-post-kuser" },
};

static void child_unmap_wine_reserve(const char* tag) {
    for (unsigned i = 0; i < sizeof(s_wine_reserve)/sizeof(s_wine_reserve[0]); i++) {
        int rc = munmap((void*)s_wine_reserve[i].base, s_wine_reserve[i].size);
        int e  = rc ? errno : 0;
        fprintf(stderr, "[child-unmap %s] %s @0x%lx+0x%lx rc=%d errno=%d\n",
            tag, s_wine_reserve[i].name,
            s_wine_reserve[i].base, s_wine_reserve[i].size, rc, e);
    }
    fflush(stderr);
}

static void child_reserve_wine_holes(const char* tag) {
    for (unsigned i = 0; i < sizeof(s_wine_reserve)/sizeof(s_wine_reserve[0]); i++) {
        void* got = mmap((void*)s_wine_reserve[i].base, s_wine_reserve[i].size,
                         PROT_NONE,
                         MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
        int rc = (got == MAP_FAILED) ? -1
               : (got != (void*)s_wine_reserve[i].base) ? -2 : 0;
        int e  = (got == MAP_FAILED) ? errno : 0;
        fprintf(stderr, "[child-reserve %s] %s @0x%lx+0x%lx -> %p rc=%d errno=%d\n",
            tag, s_wine_reserve[i].name,
            s_wine_reserve[i].base, s_wine_reserve[i].size, got, rc, e);
    }
    fflush(stderr);
}

static void apply_envp(char* const envp[]) {
    if (!envp || envp == environ) return;
    for (int i = 0; envp[i]; ++i) {
        char* kv = envp[i];
        char* eq = strchr(kv, '=');
        if (!eq) continue;
        size_t klen = (size_t)(eq - kv);
        char keybuf[256];
        if (klen == 0 || klen >= sizeof(keybuf)) continue;
        memcpy(keybuf, kv, klen);
        keybuf[klen] = 0;
        setenv(keybuf, eq + 1, 1);
    }
}

/* Copy argv into a fresh blob so the child's later free()s on the parent
 * heap don't corrupt our argv array. */
static int build_argv_blob(char* const argv[], int argc,
                           const char*** out_argv, char** out_blob) {
    size_t total = 0;
    for (int i = 0; i < argc; i++) total += strlen(argv[i]) + 1;
    char* blob = (char*)malloc(total + 64);
    const char** av = (const char**)malloc(sizeof(char*) * (argc + 1));
    if (!blob || !av) { free(blob); free(av); return -1; }
    size_t off = 0;
    for (int i = 0; i < argc; i++) {
        size_t n = strlen(argv[i]) + 1;
        memcpy(blob + off, argv[i], n);
        av[i] = blob + off;
        off += n;
    }
    av[argc] = NULL;
    *out_argv = av;
    *out_blob = blob;
    return 0;
}

/* ================================================================
 * [4] strategy: NATIVE
 * ================================================================ */
static int execve_native(const char* path,
                         char* const argv[], char* const envp[]) {
    fprintf(stderr, "[spawn-native] execve(%s)\n", path ? path : "(null)");
    return execve(path, argv, envp ? envp : environ);
}

static int spawn_native(int* outpid, const char* path,
                        char* const argv[], char* const envp[]) {
    fprintf(stderr, "[spawn-native] posix_spawn(%s)\n", path ? path : "(null)");
    pid_t pid = -1;
    int rc = posix_spawn(&pid, path, NULL, NULL,
                         argv, envp ? envp : environ);
    if (rc == 0 && outpid) *outpid = (int)pid;
    return rc;
}

/* ================================================================
 * [5] strategy: FORK (fork + box64_run)
 * ================================================================ */
static int execve_fork(const char* path,
                       char* const argv[], char* const envp[]) {
    (void)path;
    int argc = count_argv(argv);
    if (argc == 0) { errno = EINVAL; return -1; }

    fprintf(stderr,
        "[spawn-fork] execve fork+box64_run argc=%d argv[0]=%s argv[1]=%s\n",
        argc, argv[0], argc > 1 ? argv[1] : "(none)");
    fflush(stderr);

    pid_t pid = fork();
    if (pid < 0) return -1;

    if (pid == 0) {
        /* ---- child ---- */
        apply_envp(envp);
        child_unmap_wine_reserve("exec");
        child_reserve_wine_holes("exec");

        const char** argv2 = NULL; char* blob = NULL;
        if (build_argv_blob(argv, argc, &argv2, &blob) < 0) {
            fprintf(stderr, "[spawn-fork child] OOM, _exit 126\n");
            _exit(126);
        }
        int rc = box64_run(argc, argv2, (const char**)environ);
        fprintf(stderr,
            "[spawn-fork child] box64_run returned %d, _exit\n", rc);
        fflush(NULL);
        _exit(rc & 0xff);
    }

    /* ---- parent ---- */
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) _exit(127);
    }
    int code;
    if      (WIFEXITED(status))   code = WEXITSTATUS(status);
    else if (WIFSIGNALED(status)) code = 128 + WTERMSIG(status);
    else                          code = 1;

    fprintf(stderr, "[spawn-fork] child pid=%d exited code=%d, _exit(self)\n",
        (int)pid, code);
    fflush(NULL);
    _exit(code);   /* execve semantics: never return on success */
}

static int spawn_fork(int* outpid, const char* path,
                      char* const argv[], char* const envp[]) {
    (void)path;
    int argc = count_argv(argv);
    if (argc == 0) { return ENOENT; }

    fprintf(stderr,
        "[spawn-fork] posix_spawn fork+box64_run argc=%d argv[0]=%s argv[1]=%s\n",
        argc, argv[0], argc > 1 ? argv[1] : "(none)");
    fflush(stderr);

    pid_t pid = fork();
    if (pid < 0) return errno;

    if (pid == 0) {
        /* ---- child ---- */
        apply_envp(envp);
        child_unmap_wine_reserve("spawn");
        child_reserve_wine_holes("spawn");

        const char** argv2 = NULL; char* blob = NULL;
        if (build_argv_blob(argv, argc, &argv2, &blob) < 0) {
            fprintf(stderr, "[spawn-fork spawn-child] OOM, _exit 126\n");
            _exit(126);
        }
        int rc = box64_run(argc, argv2, (const char**)environ);
        fprintf(stderr,
            "[spawn-fork spawn-child] box64_run returned %d, _exit\n", rc);
        fflush(NULL);
        _exit(rc & 0xff);
    }

    if (outpid) *outpid = (int)pid;
    fprintf(stderr,
        "[spawn-fork] spawn forked child pid=%d, returning 0\n", (int)pid);
    fflush(stderr);
    return 0;
}

/* ================================================================
 * [6] strategy: SOCK (delegate to HAP main process)
 * ================================================================ */
#define SOCK_REQ_BUF_CAP   (256 * 1024)
#define SOCK_RESP_BUF_CAP  (16  * 1024)

static int sock_request(const char* exe, char* const argv[], char* const envp[],
                        int wait_flag,
                        int* out_status_ok, pid_t* out_pid,
                        int* out_exit_code, char* errmsg, size_t errmsg_cap) {
    int fd = sock_connect();
    if (fd < 0) {
        fprintf(stderr, "[spawn-sock] connect failed: %s\n", strerror(errno));
        return -1;
    }

    char* req = (char*)malloc(SOCK_REQ_BUF_CAP);
    char* rsp = (char*)malloc(SOCK_RESP_BUF_CAP);
    if (!req || !rsp) { free(req); free(rsp); close(fd); return -1; }

    int rn = build_create_req(req, SOCK_REQ_BUF_CAP,
                              exe, argv, envp, wait_flag);
    if (rn < 0) {
        fprintf(stderr, "[spawn-sock] request build overflow\n");
        free(req); free(rsp); close(fd); return -1;
    }

    if (frame_write(fd, req, (size_t)rn) < 0) {
        fprintf(stderr, "[spawn-sock] frame_write failed: %s\n", strerror(errno));
        free(req); free(rsp); close(fd); return -1;
    }

    size_t got = 0;
    if (frame_read(fd, rsp, SOCK_RESP_BUF_CAP, &got) < 0) {
        fprintf(stderr, "[spawn-sock] frame_read failed: %s\n", strerror(errno));
        free(req); free(rsp); close(fd); return -1;
    }

    parse_create_resp(rsp, got, out_status_ok, out_pid, out_exit_code,
                      errmsg, errmsg_cap);

    free(req); free(rsp); close(fd);
    return 0;
}

static int execve_sock(const char* path,
                       char* const argv[], char* const envp[]) {
    (void)path;
    int status_ok = 0;
    pid_t pid = -1;
    int   exit_code = -1;
    char  msg[256] = {0};
    int rc = sock_request(argv ? argv[0] : path, argv, envp,
                          /*wait_flag=*/1,
                          &status_ok, &pid, &exit_code, msg, sizeof(msg));
    if (rc < 0 || !status_ok) {
        if (!status_ok && rc == 0) {
            fprintf(stderr, "[spawn-sock] server error: %s\n", msg);
        }
        return -1;   /* signal fallback to fork */
    }
    fprintf(stderr,
        "[spawn-sock] sync spawn ok pid=%d exit=%d, _exit(self)\n",
        (int)pid, exit_code);
    fflush(NULL);
    _exit(exit_code & 0xff);
}

static int spawn_sock(int* outpid, const char* path,
                      char* const argv[], char* const envp[]) {
    (void)path;
    int status_ok = 0;
    pid_t pid = -1;
    char  msg[256] = {0};
    int rc = sock_request(argv ? argv[0] : path, argv, envp,
                          /*wait_flag=*/0,
                          &status_ok, &pid, NULL, msg, sizeof(msg));
    if (rc < 0 || !status_ok) {
        if (!status_ok && rc == 0) {
            fprintf(stderr, "[spawn-sock] server error: %s\n", msg);
        }
        return -1;   /* signal fallback to fork */
    }
    if (outpid) *outpid = (int)pid;
    fprintf(stderr, "[spawn-sock] async spawn ok pid=%d\n", (int)pid);
    return 0;
}

/* ================================================================
 * [7] public dispatchers
 * ================================================================ */
__attribute__((visibility("default")))
int box64_self_execve(const char* path, char* const argv[], char* const envp[]) {
    enum spawn_strategy s = get_strategy();

    if (s == SP_SOCK && !s_sock_broken) {
        int rc = execve_sock(path, argv, envp);
        /* execve_sock only returns on failure */
        s_sock_broken = 1;
        fprintf(stderr, "[box64-spawn] sock failed, falling back to fork\n");
        (void)rc;
        s = SP_FORK;
    }

    if (s == SP_NATIVE) return execve_native(path, argv, envp);
    if (s == SP_FORK)   return execve_fork(path, argv, envp);
    return execve_fork(path, argv, envp);
}

__attribute__((visibility("default")))
int box64_self_execv(const char* path, char* const argv[]) {
    return box64_self_execve(path, argv, environ);
}

__attribute__((visibility("default")))
int box64_self_posix_spawn(int* outpid, const char* path,
                           const posix_spawn_file_actions_t* facts,
                           const posix_spawnattr_t* attr,
                           char* const argv[], char* const envp[]) {
    (void)facts; (void)attr;
    enum spawn_strategy s = get_strategy();

    if (s == SP_SOCK && !s_sock_broken) {
        int rc = spawn_sock(outpid, path, argv, envp);
        if (rc == 0) return 0;
        s_sock_broken = 1;
        fprintf(stderr, "[box64-spawn] sock failed, falling back to fork\n");
        s = SP_FORK;
    }

    if (s == SP_NATIVE) return spawn_native(outpid, path, argv, envp);
    return spawn_fork(outpid, path, argv, envp);
}

__attribute__((visibility("default")))
int box64_self_posix_spawnp(int* outpid, const char* path,
                            const posix_spawn_file_actions_t* facts,
                            const posix_spawnattr_t* attr,
                            char* const argv[], char* const envp[]) {
    /* path search not done here: callers already resolved to absolute */
    return box64_self_posix_spawn(outpid, path, facts, attr, argv, envp);
}
EOF_SPAWN
    echo "    [#80]   + $f"

    if _already "$cm" "$mark"; then
        echo "    [#80]   CMakeLists.txt — already patched"
    else
        echo "    [#80]   append target_sources to CMakeLists.txt"
        cat >> "$cm" << EOF_CM
# $mark =====================================
if(TARGET box64)
    target_sources(box64 PRIVATE \${CMAKE_SOURCE_DIR}/src/box64_spawn.c)
endif()
# =========================================
EOF_CM
    fi
}

# ================================================================
# Patch 81 — 调用点路由: 7 处 execv/execve/posix_spawn{,p}
# ================================================================
# 把 box64 内部 self-spawn 改写后的调用点都路由到 patch 80 的
# box64_self_* dispatcher.
#
# 调用点 (基于 vanilla source, grep 已确认):
#   src/wrapped/wrappedlibc.c
#     L2790  execve(newargv[0], (char* const*)newargv, envv)
#     L2792  execv (newargv[0], (char* const*)newargv)
#     L2844  execve(newargv[0], (char* const*)newargv, envp)
#     L2853  return execve(path, argv2, envp)         (uname -m 重定向)
#     L3209  posix_spawn (pid, newargv[0], actions, attrp, ...)
#     L3253  posix_spawn (pid, newargv[0], actions, attrp, ...)
#
#   src/wrapped32/wrappedlibc.c
#     L1949  execv (newargv[0], ...)
#     L2030  execve(newargv[0], ..., newenvp)
#     L2082  execv (newargv[0], ...)
#     L2141  execve(newargv[0], ..., newenvp)
#     L2273  posix_spawnp(pid, newargv[0], ...)
#     L2325  posix_spawnp(pid, newargv[0], ...)
#
#   src/core.c
#     L1268  execve(my_context->box64path, (void*)argv, newenv)
#     L1400  execve(newargv[0], newargv, newenv)
#
# 替换规则 (与 vanilla 匹配):
#   execv(newargv[0]            -> box64_self_execv(newargv[0]
#   execve(newargv[0]           -> box64_self_execve(newargv[0]
#   posix_spawn (pid, newargv[0]  -> box64_self_posix_spawn (pid, newargv[0]
#   posix_spawnp(pid, newargv[0]  -> box64_self_posix_spawnp(pid, newargv[0]
#   return execve(path, argv2, envp);
#                              -> return box64_self_execve(path, argv2, envp);
#   execve(my_context->box64path, (void*)argv, newenv)
#                              -> box64_self_execve(my_context->box64path, (void*)argv, newenv)
#   execve(newargv[0], newargv, newenv)
#                              -> box64_self_execve(newargv[0], newargv, newenv)
patch_81_route_self_exec() {
    local mark='OHOS_PATCH_ROUTE_SELF_EXEC_V2'
    local hdr="\\
/* $mark */\\
extern int box64_self_execv (const char* path, char* const argv[]);\\
extern int box64_self_execve(const char* path, char* const argv[], char* const envp[]);\\
extern int box64_self_posix_spawn (int* outpid, const char* path,\\
                                   const void* facts, const void* attr,\\
                                   char* const argv[], char* const envp[]);\\
extern int box64_self_posix_spawnp(int* outpid, const char* path,\\
                                   const void* facts, const void* attr,\\
                                   char* const argv[], char* const envp[]);"

    # ---- 64-bit wrappedlibc.c ----
    local f1="$BOX64/src/wrapped/wrappedlibc.c"
    if [ -f "$f1" ] && ! _already "$f1" "$mark"; then
        _patch_header 81 "src/wrapped/wrappedlibc.c" "route 6 self-exec sites"
        sed -i "1i$hdr" "$f1"

        # newargv[0] 系列
        sed -i 's|\bexecv(newargv\[0\]|box64_self_execv(newargv[0]|g'   "$f1"
        sed -i 's|\bexecve(newargv\[0\]|box64_self_execve(newargv[0]|g' "$f1"
        sed -i 's|\bposix_spawn(pid, newargv\[0\]|box64_self_posix_spawn(pid, newargv[0]|g' "$f1"
        # 兼容大小写空格 (vanilla 是 'posix_spawn(pid, newargv[0]')
        # uname -m 重定向那一行
        sed -i 's|return execve(path, argv2, envp);|return box64_self_execve(path, argv2, envp);|' "$f1"
    fi

    # ---- 32-bit wrappedlibc.c ----
    local f2="$BOX64/src/wrapped32/wrappedlibc.c"
    if [ -f "$f2" ] && ! _already "$f2" "$mark"; then
        _patch_header 81 "src/wrapped32/wrappedlibc.c" "route 6 self-exec sites"
        sed -i "1i$hdr" "$f2"

        sed -i 's|\bexecv(newargv\[0\]|box64_self_execv(newargv[0]|g'   "$f2"
        sed -i 's|\bexecve(newargv\[0\]|box64_self_execve(newargv[0]|g' "$f2"
        sed -i 's|\bposix_spawnp(pid, newargv\[0\]|box64_self_posix_spawnp(pid, newargv[0]|g' "$f2"
    fi

    # ---- core.c ----
    local f3="$BOX64/src/core.c"
    if [ -f "$f3" ] && ! _already "$f3" "$mark"; then
        _patch_header 81 "src/core.c" "route 2 self-exec sites"
        sed -i "1i$hdr" "$f3"

        sed -i 's|execve(my_context->box64path, (void\*)argv, newenv)|box64_self_execve(my_context->box64path, (void*)argv, newenv)|' "$f3"
        sed -i 's|execve(newargv\[0\], newargv, newenv)|box64_self_execve(newargv[0], newargv, newenv)|' "$f3"
    fi
}

# ================================================================
# Patch 82 — 把 OHOS bring-up 诊断输出按 BOX64_LOG 分级
# ================================================================
# 上游已把 box64_log 全局变量换成 BOX64ENV(log) 宏访问, 不便从
# 我们这几个独立 .c 文件读. 改用各文件自己读 BOX64_LOG env var,
# static 缓存. 与上游 box64 实际 log level 一致 (上游也读同一个
# env var, 只是数值在 env_layout.c 里解析).
#
# 分级:
#   BOX64_LOG=0 (默认): 静默. 仅 fatal 错误 (connect failed / fallback /
#                       OOM 等用户必须看见的).
#   BOX64_LOG>=1 INFO : 每次 spawn / 模块 init 概要 1 行
#   BOX64_LOG>=2 DEBUG: mmap-noreplace, child-unmap/reserve 等 per-call.
patch_82_log_gate() {
    local mark='OHOS_PATCH_LOG_GATE'

    # ---- 公用 helper 注入函数 ----
    # 把同样的 helper 装到 4 个 .c 文件顶部. helper 名字不同避免符号冲突.
    # (static, 同名也不会冲突, 但为可读性区分.)
    _inject_log_helper() {
        local file="$1"
        local prefix="$2"   # 例如: ohos_spawn / ohos_remap / ohos_sigsys / ohos_wrappedlibc
        python3 - "$file" "$mark" "$prefix" << 'PY'
import sys, re
p, mark, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
if mark in s:
    sys.exit(0)

helper = '''/* %s */
#include <stdlib.h>
#include <stdio.h>
static int %s_log_level(void) {
    static int cached = -1;
    if (cached < 0) {
        const char* v = getenv("BOX64_LOG");
        cached = (v && *v) ? atoi(v) : 0;
        if (cached < 0) cached = 0;
    }
    return cached;
}
#define %s_INFO(...)  do { if (%s_log_level() >= 1) { fprintf(stderr, __VA_ARGS__); fflush(stderr); } } while (0)
#define %s_DEBUG(...) do { if (%s_log_level() >= 2) { fprintf(stderr, __VA_ARGS__); fflush(stderr); } } while (0)
''' % (mark, prefix, prefix.upper(), prefix, prefix.upper(), prefix)

# 找最后一个 #include 行后面插入
m = list(re.finditer(r'^#include\s+[<"][^>"]+[>"]\s*\n', s, re.M))
if not m:
    print("ERROR: no #include found in %s" % p, file=sys.stderr)
    sys.exit(1)
last = m[-1]
s = s[:last.end()] + '\n' + helper + s[last.end():]
open(p, 'w').write(s)
print("  log helper injected into %s (prefix=%s)" % (p, prefix))
PY
    }

    # ---- 1) box64_spawn.c (patch 80) ----
    local f1="$BOX64/src/box64_spawn.c"
    if [ -f "$f1" ] && ! grep -q "$mark" "$f1"; then
        _patch_header 82 "box64_spawn.c" "gate child-unmap/reserve + spawn trace"
        _inject_log_helper "$f1" "ohos_spawn"
        python3 - "$f1" << 'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
# DEBUG: 高频 per-fork trace (每次 fork 4 行 x 2 段)
s = re.sub(r'fprintf\(\s*stderr\s*,\s*"\[child-(unmap|reserve)',
           r'OHOS_SPAWN_DEBUG("[child-\1', s)
# INFO: 每次 spawn 概要
s = re.sub(r'fprintf\(\s*stderr\s*,\s*"\[box64-spawn\] strategy=',
           'OHOS_SPAWN_INFO("[box64-spawn] strategy=', s)
s = re.sub(r'fprintf\(\s*stderr\s*,\s*\n\s*"\[spawn-fork\]',
           'OHOS_SPAWN_INFO(\n        "[spawn-fork]', s)
s = re.sub(r'fprintf\(\s*stderr\s*,\s*"\[spawn-fork\]',
           'OHOS_SPAWN_INFO("[spawn-fork]', s)
s = re.sub(r'fprintf\(\s*stderr\s*,\s*"\[spawn-native\]',
           'OHOS_SPAWN_INFO("[spawn-native]', s)
s = re.sub(r'fprintf\(\s*stderr\s*,\s*\n\s*"\[spawn-sock\] sync spawn ok',
           'OHOS_SPAWN_INFO(\n        "[spawn-sock] sync spawn ok', s)
s = re.sub(r'fprintf\(\s*stderr\s*,\s*"\[spawn-sock\] async spawn ok',
           'OHOS_SPAWN_INFO("[spawn-sock] async spawn ok', s)
# 保持 fprintf 不变的错误类:
#   [spawn-sock] connect failed / server error / frame_* failed / request build overflow
#   [spawn-fork child] OOM
#   [box64-spawn] sock failed, falling back to fork
open(p, 'w').write(s)
print("  patch_82 box64_spawn.c: gated")
PY
    fi

    # ---- 2) wrappedlibc.c mmap-noreplace (patch 72) ----
    local f2="$BOX64/src/wrapped/wrappedlibc.c"
    if [ -f "$f2" ] && ! grep -q "$mark" "$f2"; then
        _patch_header 82 "wrappedlibc.c" "gate [mmap-noreplace]"
        # 用 sed 在 patch 09 prologue 之后注入 helper. 不能用 _inject_log_helper
        # 因为 wrappedlibc.c 顶部已经被 patch 09/10/65/66 加了一堆东西,
        # last include 位置不稳定. 直接在文件最末尾追加 helper.
        # 然后再把 fprintf 替换成宏调用. 宏访问 helper 函数, 静态链接,
        # 调用站点在 my_mmap64 中, 没问题.
        cat >> "$f2" << EOF_HELPER

/* $mark — log gate helper (appended at EOF, used by my_mmap64) */
#include <stdlib.h>
static int ohos_wrappedlibc_log_level(void) {
    static int cached = -1;
    if (cached < 0) {
        const char* v = getenv("BOX64_LOG");
        cached = (v && *v) ? atoi(v) : 0;
        if (cached < 0) cached = 0;
    }
    return cached;
}
EOF_HELPER

        # 替换 fprintf 调用. 注意 my_mmap64 在文件中间, 调用 helper
        # 是前向引用 -- C 里函数声明可以隐式 (int(...)), static 定义
        # 在后没问题, 但保险起见, 我们在调用点前加 forward decl.
        python3 - "$f2" << 'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()

# 在 my_mmap64 函数定义之前插入 forward decl
anchor = 'EXPORT void* my_mmap64('
if anchor not in s:
    print("ERROR: my_mmap64 anchor not found", file=sys.stderr); sys.exit(1)
fwd = '/* OHOS_PATCH_LOG_GATE forward decl */\nstatic int ohos_wrappedlibc_log_level(void);\n\n'
s = s.replace(anchor, fwd + anchor, 1)

# 替换 mmap-noreplace 那一行 fprintf 为条件打印.
# patch 72 注入的代码是:
#   fprintf(stderr,
#       "[mmap-noreplace] addr=%p len=0x%lx prot=0x%x flags=0x%x "
#       "%s -> %p errno=%d\n",
#       addr, ...);
# 找到这个多行 fprintf, 把外层包成 if.
pat = re.compile(
    r'(fprintf\(\s*stderr\s*,\s*\n\s*"\[mmap-noreplace\].*?\);)',
    re.DOTALL)
def repl(m):
    return ('if (ohos_wrappedlibc_log_level() >= 2) {\n            '
            + m.group(1) + '\n        }')
new_s, n = pat.subn(repl, s)
if n < 1:
    print("WARN: mmap-noreplace fprintf not matched", file=sys.stderr)
open(p, 'w').write(new_s)
PY
    fi

    # ---- 3) box64_path_remap.c (patch 65/66) ----
    local f3="$BOX64/src/box64_path_remap.c"
    if [ -f "$f3" ] && ! grep -q "$mark" "$f3"; then
        _patch_header 82 "box64_path_remap.c" "gate [box64-remap] setup lines"
        _inject_log_helper "$f3" "ohos_remap"
        python3 - "$f3" << 'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
# /tmp -> ... (启动期 1 行)
s = re.sub(r'fprintf\(\s*stderr\s*,\s*\n?\s*"\[box64-remap\] /tmp ->',
           'OHOS_REMAP_INFO("[box64-remap] /tmp ->', s)
# WINEPREFIX/dosdevices/c: -> ... (启动期 1 行)
s = re.sub(r'fprintf\(\s*stderr\s*,\s*"\[box64-remap\] %s -> %s',
           'OHOS_REMAP_INFO("[box64-remap] %s -> %s', s)
# WARN 类 (target not writable / sun_path too long / faked symlink)
# 保持 fprintf 不变
open(p, 'w').write(s)
PY
    fi

    # ---- 4) sigsys_fallback.c (patch 50) ----
    local f4="$BOX64/src/sigsys_fallback.c"
    if [ -f "$f4" ] && ! grep -q "$mark" "$f4"; then
        _patch_header 82 "sigsys_fallback.c" "gate SIGSYS installed line"
        # sigsys_fallback.c 用的是 write(2,...) 不是 fprintf. 单独处理.
        python3 - "$f4" "$mark" << 'PY'
import sys
p, mark = sys.argv[1], sys.argv[2]
s = open(p).read()
if mark in s:
    sys.exit(0)

helper = '''
/* %s */
#include <stdlib.h>
static int ohos_sigsys_log_level(void) {
    static int cached = -1;
    if (cached < 0) {
        const char* v = getenv("BOX64_LOG");
        cached = (v && *v) ? atoi(v) : 0;
        if (cached < 0) cached = 0;
    }
    return cached;
}
''' % mark

# 顶部加 helper. 找 #include <stdio.h> 之后插入.
m = s.find('#include <stdio.h>')
if m < 0:
    print("ERROR: no <stdio.h> in sigsys_fallback.c", file=sys.stderr); sys.exit(1)
eol = s.find('\n', m)
s = s[:eol+1] + helper + s[eol+1:]

# 把 SIGSYS installed write 包条件
old = '''        const char *m = "[box64] SIGSYS fallback installed\\n";
        (void)!write(2, m, strlen(m));'''
if old in s:
    new = '''        if (ohos_sigsys_log_level() >= 1) {
            const char *m = "[box64] SIGSYS fallback installed\\n";
            (void)!write(2, m, strlen(m));
        }'''
    s = s.replace(old, new, 1)
else:
    print("WARN: SIGSYS installed write not matched", file=sys.stderr)

# WARN: install failed 保持原样, 不改
open(p, 'w').write(s)
PY
    fi
}

# ================================================================
# Patch 83 — sock 策略走 SCM_RIGHTS 传递 envp 引用的 fd
# ================================================================
# 现象:
#   wineboot --init 在 sock 模式下间歇性失败:
#       0024:err:environ:run_wineboot failed to start wineboot 1
#       [BOX64] N|Ask to run at NULL, will segfault
#
# 根因:
#   wine 用 WINESERVERSOCKET=<fd 数字> 通过 envp 把 wineserver 连接
#   socket 传给子进程, 依赖 fork 的 fd 表继承.
#   sock 策略下子进程是 HAP main 的孩子, fd 表完全不同, 子进程拿
#   到的 WINESERVERSOCKET=7 在自己的 fd 表里要么无效要么是无关 fd,
#   wineserver 握手错乱, wineboot 提前夭折.
#
# 修法:
#   spawn 请求帧加:
#     PROTO_VER 2                ← 协议版本
#     FDREF <target_fd>          ← 每个继承 fd 一行
#   同时用 SCM_RIGHTS 把 fd 通过 unix socket 真实送到 procmgr.
#   procmgr 在 fork 出的 child 里 dup2(source_fd, target_fd) 还原
#   父进程视角的 fd 号. wine 子进程看到的 WINESERVERSOCKET=7 真的
#   指向 wineserver socket.
#
#   白名单只匹配已知 fd 类环境变量, 当前只有 WINESERVERSOCKET.
#   再撞别的, 直接加到 kBox64FdInheritVars[] 即可.
#
# 兼容:
#   PROTO_VER 行未出现时, procmgr 走老逻辑. 新旧组合在最差情况下
#   退化为本 bug 的现状, 不会更糟.
patch_83_sock_fd_inherit() {
    local f="$BOX64/src/box64_spawn.c"
    local mark='OHOS_PATCH_SOCK_FD_INHERIT'

    [ -f "$f" ] || { _patch_header 83 "(skip) box64_spawn.c not found" ""; return 0; }
    if _already "$f" "$mark"; then
        _patch_header 83 "src/box64_spawn.c" "sock fd inherit — already"
        return 0
    fi
    if ! grep -q 'OHOS_PATCH_BOX64_SPAWN' "$f"; then
        _patch_header 83 "(skip) patch 80 not applied yet" ""
        return 0
    fi
    _patch_header 83 "src/box64_spawn.c" \
        "SCM_RIGHTS fd inheritance via sock strategy"

    python3 - "$f" "$mark" << 'PY'
import sys
p, mark = sys.argv[1], sys.argv[2]
s = open(p).read()

if mark in s:
    sys.exit(0)

# ---- 1) 顶部加 <sys/uio.h> (struct iovec) ----
inc_old = '#include <sys/socket.h>'
inc_new = '#include <sys/socket.h>\n#include <sys/uio.h>      /* OHOS_PATCH_SOCK_FD_INHERIT */'
if inc_old in s and '<sys/uio.h>' not in s:
    s = s.replace(inc_old, inc_new, 1)

# ---- 2) 在 sock client 段开头插入 helpers ----
anchor1 = ('/* ================================================================\n'
           ' * [2] socket client (used by sock strategy)\n'
           ' * ================================================================ */')
if anchor1 not in s:
    print("ERROR: anchor1 (socket client header) not found", file=sys.stderr)
    sys.exit(1)

helpers = r'''

/* ==== OHOS_PATCH_SOCK_FD_INHERIT helpers ====
 * Whitelist envp keys whose value is "an fd number" we must forward
 * via SCM_RIGHTS so the procmgr-spawned child sees the same fd
 * number its parent did. */

#define BOX64_FD_REF_MAX 16

typedef struct {
    int  target_fd;   /* number child must see (same as current proc fd) */
    int  source_fd;   /* fd in current process, payload of SCM_RIGHTS */
    char name[64];    /* env var name, for logging */
} box64_fd_ref_t;

static const char* const kBox64FdInheritVars[] = {
    "WINESERVERSOCKET",
    NULL
};

static int collect_envp_fd_refs(char* const envp[],
                                box64_fd_ref_t* out, int max) {
    if (!envp || !out || max <= 0) return 0;
    int n = 0;
    for (int i = 0; envp[i] && n < max; i++) {
        const char* e = envp[i];
        const char* eq = strchr(e, '=');
        if (!eq) continue;
        size_t name_len = (size_t)(eq - e);
        for (int j = 0; kBox64FdInheritVars[j]; j++) {
            const char* vn = kBox64FdInheritVars[j];
            if (strlen(vn) != name_len) continue;
            if (memcmp(e, vn, name_len) != 0) continue;
            const char* val = eq + 1;
            if (!*val) break;
            char* end = NULL;
            long fd = strtol(val, &end, 10);
            if (end == val || fd < 3 || fd > 65535) break;
            if (fcntl((int)fd, F_GETFD) < 0) {
                fprintf(stderr,
                    "[spawn-sock] WARN env %s=%ld fd invalid: %s\n",
                    vn, fd, strerror(errno));
                break;
            }
            out[n].target_fd = (int)fd;
            out[n].source_fd = (int)fd;
            snprintf(out[n].name, sizeof(out[n].name), "%s", vn);
            fprintf(stderr,
                "[spawn-sock] FDREF %s=%d (will SCM_RIGHTS)\n",
                vn, (int)fd);
            n++;
            break;
        }
    }
    return n;
}

/* sendmsg: [4 byte length] + payload, with optional SCM_RIGHTS.
 * Single-shot send; short send treated as fatal (cmsg only attaches
 * to first byte, recovery would lose fds). */
static int sock_send_with_fds(int sockfd, const char* payload, size_t len,
                              const box64_fd_ref_t* fds, int n_fds) {
    if (n_fds < 0) n_fds = 0;
    if (n_fds > BOX64_FD_REF_MAX) n_fds = BOX64_FD_REF_MAX;

    uint8_t hdr[4] = {
        (uint8_t)(len >> 24), (uint8_t)(len >> 16),
        (uint8_t)(len >>  8), (uint8_t) len
    };

    struct iovec iov[2];
    iov[0].iov_base = hdr;          iov[0].iov_len = 4;
    iov[1].iov_base = (void*)payload; iov[1].iov_len = len;

    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov    = iov;
    msg.msg_iovlen = 2;

    char cmsg_buf[CMSG_SPACE(sizeof(int) * BOX64_FD_REF_MAX)];
    memset(cmsg_buf, 0, sizeof(cmsg_buf));

    if (n_fds > 0) {
        msg.msg_control    = cmsg_buf;
        msg.msg_controllen = CMSG_SPACE(sizeof(int) * n_fds);
        struct cmsghdr* cm = CMSG_FIRSTHDR(&msg);
        cm->cmsg_level = SOL_SOCKET;
        cm->cmsg_type  = SCM_RIGHTS;
        cm->cmsg_len   = CMSG_LEN(sizeof(int) * n_fds);
        int* fdp = (int*)CMSG_DATA(cm);
        for (int i = 0; i < n_fds; i++) fdp[i] = fds[i].source_fd;
    }

    while (1) {
        ssize_t w = sendmsg(sockfd, &msg, MSG_NOSIGNAL);
        if (w == (ssize_t)(4 + len)) return 0;
        if (w < 0 && errno == EINTR) continue;
        return -1;
    }
}
/* ==== OHOS_PATCH_SOCK_FD_INHERIT helpers END ==== */
'''
s = s.replace(anchor1, anchor1 + helpers, 1)

# ---- 3) 改 build_create_req: 加 PROTO_VER + FDREF ----
old_build = r'''static int build_create_req(char* buf, size_t cap,
                            const char* exe,
                            char* const argv[], char* const envp[],
                            int wait_flag) {
    size_t off = 0;
    if (buf_appendf(buf, cap, &off, "CMD CREATE\n")             < 0) return -1;
    if (buf_appendf(buf, cap, &off, "REQ_ID 1\n")               < 0) return -1;
    if (buf_appendf(buf, cap, &off, "EXE %s\n", exe ? exe : "") < 0) return -1;
    if (buf_appendf(buf, cap, &off, "KIND box64\n")             < 0) return -1;
    if (buf_appendf(buf, cap, &off, "WAIT %d\n", wait_flag)     < 0) return -1;
    if (argv) {
        for (int i = 0; argv[i]; i++) {
            if (buf_appendf(buf, cap, &off, "ARG %s\n", argv[i]) < 0) return -1;
        }
    }
    if (envp) {
        for (int i = 0; envp[i]; i++) {
            if (buf_appendf(buf, cap, &off, "ENV %s\n", envp[i]) < 0) return -1;
        }
    }
    if (buf_appendf(buf, cap, &off, "END") < 0) return -1;
    return (int)off;
}'''

new_build = r'''static int build_create_req(char* buf, size_t cap,
                            const char* exe,
                            char* const argv[], char* const envp[],
                            int wait_flag,
                            const box64_fd_ref_t* fdrefs, int n_fdrefs) {
    size_t off = 0;
    if (buf_appendf(buf, cap, &off, "CMD CREATE\n")             < 0) return -1;
    /* OHOS_PATCH_SOCK_FD_INHERIT: opt-in to v2 (FDREF + SCM_RIGHTS) */
    if (buf_appendf(buf, cap, &off, "PROTO_VER 2\n")            < 0) return -1;
    if (buf_appendf(buf, cap, &off, "REQ_ID 1\n")               < 0) return -1;
    if (buf_appendf(buf, cap, &off, "EXE %s\n", exe ? exe : "") < 0) return -1;
    if (buf_appendf(buf, cap, &off, "KIND box64\n")             < 0) return -1;
    if (buf_appendf(buf, cap, &off, "WAIT %d\n", wait_flag)     < 0) return -1;
    if (argv) {
        for (int i = 0; argv[i]; i++) {
            if (buf_appendf(buf, cap, &off, "ARG %s\n", argv[i]) < 0) return -1;
        }
    }
    if (envp) {
        for (int i = 0; envp[i]; i++) {
            if (buf_appendf(buf, cap, &off, "ENV %s\n", envp[i]) < 0) return -1;
        }
    }
    /* FDREF order MUST match SCM_RIGHTS fd order. */
    for (int i = 0; i < n_fdrefs; i++) {
        if (buf_appendf(buf, cap, &off, "FDREF %d\n",
                        fdrefs[i].target_fd) < 0) return -1;
    }
    if (buf_appendf(buf, cap, &off, "END") < 0) return -1;
    return (int)off;
}'''

if old_build not in s:
    print("ERROR: anchor2 (build_create_req) not matched", file=sys.stderr)
    sys.exit(1)
s = s.replace(old_build, new_build, 1)

# ---- 4) 改 sock_request: 收集 fds + 用 sendmsg ----
old_send = r'''    int rn = build_create_req(req, SOCK_REQ_BUF_CAP,
                              exe, argv, envp, wait_flag);
    if (rn < 0) {
        fprintf(stderr, "[spawn-sock] request build overflow\n");
        free(req); free(rsp); close(fd); return -1;
    }

    if (frame_write(fd, req, (size_t)rn) < 0) {
        fprintf(stderr, "[spawn-sock] frame_write failed: %s\n", strerror(errno));
        free(req); free(rsp); close(fd); return -1;
    }'''

new_send = r'''    /* OHOS_PATCH_SOCK_FD_INHERIT: pick out envp-referenced fds. */
    box64_fd_ref_t fdrefs[BOX64_FD_REF_MAX];
    int n_fdrefs = collect_envp_fd_refs(envp, fdrefs, BOX64_FD_REF_MAX);

    int rn = build_create_req(req, SOCK_REQ_BUF_CAP,
                              exe, argv, envp, wait_flag,
                              fdrefs, n_fdrefs);
    if (rn < 0) {
        fprintf(stderr, "[spawn-sock] request build overflow\n");
        free(req); free(rsp); close(fd); return -1;
    }

    if (sock_send_with_fds(fd, req, (size_t)rn, fdrefs, n_fdrefs) < 0) {
        fprintf(stderr, "[spawn-sock] sendmsg failed: %s\n", strerror(errno));
        free(req); free(rsp); close(fd); return -1;
    }'''

if old_send not in s:
    print("ERROR: anchor3 (sock_request send) not matched", file=sys.stderr)
    sys.exit(1)
s = s.replace(old_send, new_send, 1)

# ---- mark at top ----
if '/* ' + mark + ' */' not in s:
    s = '/* ' + mark + ' */\n' + s

open(p, 'w').write(s)
PY
}



# ================================================================
# 调度
# ================================================================
echo "==> apply patches in: $BOX64"

patch_01_mallopt
patch_02_pthread_np
patch_03_fts
patch_04_sigset_t
patch_05_pthread_cleanup
patch_06_obstack
patch_07_error_h
patch_08_dlinfo_consts
patch_09_wrappedlibc
patch_10_wrappedlibc_more
patch_11_config_h
patch_12_musl_compat
patch_13_disable_mallochook
patch_15_custommem_no_curbrk
patch_16_rtld_next_to_default
patch_17_skip_box64lib_dlopen
patch_18_skip_pthread_dlsym
patch_19_no_pre_init_dlopen
patch_20_libdl_rename_shims
# ---- BOX32 wave 1 ---------------------------------------------
patch_21_myalign32_glibc_types
patch_22_signal32_glibc_compat
patch_23_libc_net32_skip_glibc_hooks
patch_24_threads32_pthread
patch_25_myalign32_obstack_skip
patch_26_wrappedlibc32
patch_27_box32_link_stubs
patch_28_box32_low4gb_allocator
patch_31_box32_no_abort
patch_32_box32_warn_caller
patch_33_box32_prefill_io_globdata
patch_34_box32_alloc_via_low4gb
patch_35_box32_iomap
#
patch_36_box32_mmap_hard_search
# ---- V4 wave: .so build ---------------------------------------
patch_50_sigsys_fallback
patch_51_box64_run_entry
patch_52_rename_main
patch_53_cmake_to_shared
# ---- self-exec via fork+box64_run ------------------------------
# patch_60_self_exec_helper
# patch_61_route_self_exec
patch_62_mmap_noreplace_fallback
patch_63_wine_kuser_hole
# patch_64_self_posix_spawn
patch_65_path_remap
patch_66_path_remap_v2
patch_67_path_remap_v3_missing_wrappers
# patch_68_path_remap_trace
# patch_70_child_unmap_wine_reserve
# patch_71_child_reserve_wine_holes
patch_72_mmap_noreplace_split
# ---- self-exec via three-strategy dispatcher (patch 80/81) -----
patch_80_box64_spawn
patch_81_route_self_exec
# ---- diagnostic log gating ------------------------------------
patch_82_log_gate
patch_83_sock_fd_inherit

echo "    all patches applied."