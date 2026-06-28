#include "wineprefix_setup.h"
#include "napi_utils.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/sendfile.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <string>
#include <vector>

#undef  LOG_TAG
#define LOG_TAG "HBox_NAPI_WPF"
#include <hilog/log.h>

namespace wineprefix {

namespace {

// ============================================================
// 工具: 路径 / 文件系统判断
// ============================================================

bool IsDir(const std::string& path) {
    struct stat st;
    return stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

bool IsRegFile(const std::string& path) {
    struct stat st;
    return stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

bool FileNonEmpty(const std::string& path) {
    struct stat st;
    return stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0;
}

off_t FileSize(const std::string& path) {
    struct stat st;
    if (stat(path.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) return -1;
    return st.st_size;
}

// 递归 mkdir, EEXIST 不算错.
bool MkdirP(const std::string& path) {
    if (path.empty()) return false;
    std::string acc;
    size_t i = 0;
    if (path[0] == '/') { acc = "/"; i = 1; }
    while (i <= path.size()) {
        if (i == path.size() || path[i] == '/') {
            if (!acc.empty() && acc != "/") {
                if (mkdir(acc.c_str(), 0755) != 0 && errno != EEXIST) {
                    OH_LOG_ERROR(LOG_APP,
                        "[wineprefix] mkdir(%{public}s) failed: %{public}s",
                        acc.c_str(), strerror(errno));
                    return false;
                }
            }
            if (i < path.size() && acc.back() != '/') acc += '/';
        } else {
            acc += path[i];
        }
        i++;
    }
    return true;
}

// ============================================================
// PE 文件名归一化 / 过滤
// ============================================================

bool EndsWithCI(const std::string& s, const std::string& suf) {
    if (s.size() < suf.size()) return false;
    for (size_t i = 0; i < suf.size(); i++) {
        char a = s[s.size() - suf.size() + i];
        char b = suf[i];
        if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
        if (b >= 'A' && b <= 'Z') b = (char)(b - 'A' + 'a');
        if (a != b) return false;
    }
    return true;
}

// wine builtin 在 Linux side 文件名是 "kernel32.dll.so", PE side 要 "kernel32.dll".
// 这里把源文件名映射为 dst 文件名.
//   "kernel32.dll.so" -> "kernel32.dll"
//   "kernel32.dll"    -> "kernel32.dll"
//   "wineboot.exe.so" -> "wineboot.exe"
//   "libwine.so"      -> "libwine.so" (不是 PE, 后面会被过滤)
std::string StripSoSuffixForPE(const std::string& name) {
    static const char* exts[] = {
        ".dll.so", ".exe.so", ".drv.so", ".sys.so", ".ocx.so", ".cpl.so"
    };
    for (auto* ext : exts) {
        std::string s(ext);
        if (EndsWithCI(name, s)) {
            return name.substr(0, name.size() - 3);  // 砍掉末尾 ".so"
        }
    }
    return name;
}

// 是否运行时 PE 文件名 (剥过 .so 之后判断).
bool IsRuntimePE(const std::string& name) {
    static const char* exts[] = {
        ".dll", ".exe", ".drv", ".sys", ".ocx", ".cpl", ".acm", ".tlb"
    };
    for (auto* e : exts) if (EndsWithCI(name, e)) return true;
    return false;
}

// ============================================================
// 单文件拷贝 (sendfile, fallback read/write)
// ============================================================

bool CopyFileFallback(int sfd, int dfd, off_t total) {
    char buf[65536];
    off_t left = total;
    while (left > 0) {
        ssize_t n = read(sfd, buf, sizeof(buf));
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (n == 0) break;
        ssize_t w = 0;
        while (w < n) {
            ssize_t k = write(dfd, buf + w, n - w);
            if (k < 0) {
                if (errno == EINTR) continue;
                return false;
            }
            w += k;
        }
        left -= n;
    }
    return true;
}

bool CopyOne(const std::string& src, const std::string& dst, off_t size) {
    int sfd = open(src.c_str(), O_RDONLY | O_CLOEXEC);
    if (sfd < 0) {
        OH_LOG_ERROR(LOG_APP,
            "[wineprefix] open src %{public}s failed: %{public}s",
            src.c_str(), strerror(errno));
        return false;
    }
    int dfd = open(dst.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (dfd < 0) {
        OH_LOG_ERROR(LOG_APP,
            "[wineprefix] open dst %{public}s failed: %{public}s",
            dst.c_str(), strerror(errno));
        close(sfd);
        return false;
    }

    bool ok = true;
    off_t left = size;
    off_t off  = 0;
    while (left > 0) {
        ssize_t n = sendfile(dfd, sfd, &off, (size_t)(left > 1 << 20 ? 1 << 20 : left));
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EINVAL || errno == ENOSYS) {
                lseek(sfd, 0, SEEK_SET);
                ok = CopyFileFallback(sfd, dfd, left);
                break;
            }
            OH_LOG_ERROR(LOG_APP,
                "[wineprefix] sendfile %{public}s failed: %{public}s",
                dst.c_str(), strerror(errno));
            ok = false;
            break;
        }
        if (n == 0) break;
        left -= n;
    }

    close(sfd);
    close(dfd);
    if (!ok) unlink(dst.c_str());
    return ok;
}

// ============================================================
// 目录遍历拷贝
// ============================================================

struct CopyStat {
    int copied = 0;
    int skipped = 0;
    int failed = 0;
};

CopyStat CopyDirPE(const std::string& src_dir, const std::string& dst_dir) {
    CopyStat s;
    DIR* d = opendir(src_dir.c_str());
    if (!d) {
        OH_LOG_WARN(LOG_APP,
            "[wineprefix] opendir %{public}s: %{public}s",
            src_dir.c_str(), strerror(errno));
        return s;
    }

    struct dirent* e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        std::string raw_name(e->d_name);
        std::string dst_name = StripSoSuffixForPE(raw_name);
        if (!IsRuntimePE(dst_name)) continue;

        std::string src_path = src_dir + "/" + raw_name;
        std::string dst_path = dst_dir + "/" + dst_name;

        struct stat ss;
        if (lstat(src_path.c_str(), &ss) != 0) continue;
        if (!S_ISREG(ss.st_mode)) continue;

        // 幂等: dst 已存在且 size 一致就跳过
        struct stat ds;
        if (stat(dst_path.c_str(), &ds) == 0
            && S_ISREG(ds.st_mode)
            && ds.st_size == ss.st_size) {
            s.skipped++;
            continue;
        }

        if (CopyOne(src_path, dst_path, ss.st_size)) {
            s.copied++;
        } else {
            s.failed++;
        }
    }
    closedir(d);

    OH_LOG_INFO(LOG_APP,
        "[wineprefix] %{public}s -> %{public}s: %{public}d copied, "
        "%{public}d skipped, %{public}d failed",
        src_dir.c_str(), dst_dir.c_str(), s.copied, s.skipped, s.failed);
    return s;
}

// ============================================================
// 标记文件
// ============================================================

bool WriteMarker(const std::string& path) {
    int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return false;
    const char* msg = "v1\nbox64-wineprefix-prebuilt\n";
    ssize_t total = (ssize_t)strlen(msg);
    ssize_t written = 0;
    while (written < total) {
        ssize_t n = write(fd, msg + written, (size_t)(total - written));
        if (n < 0) {
            if (errno == EINTR) continue;
            close(fd);
            unlink(path.c_str());
            return false;
        }
        written += n;
    }
    close(fd);
    return true;
}

}  // namespace

// ============================================================
// 主入口
// ============================================================

bool SetupWinePrefix(const std::string& wineprefix,
                     const std::string& wine_root) {
    OH_LOG_INFO(LOG_APP,
        "[wineprefix] setup start: prefix=%{public}s root=%{public}s",
        wineprefix.c_str(), wine_root.c_str());

    if (wineprefix.empty() || wine_root.empty()) {
        OH_LOG_ERROR(LOG_APP, "[wineprefix] empty path");
        return false;
    }

    // ---- 0. 幂等快速通道 ----
    const std::string marker = wineprefix + "/.box64_setup_done";
    if (FileNonEmpty(marker)) {
        OH_LOG_INFO(LOG_APP,
            "[wineprefix] marker present, skip: %{public}s", marker.c_str());
        return true;
    }

    // ---- 1. 验证源 ----
    const std::string src_sys32   = wine_root + "/lib/wine/x86_64-windows";
    const std::string src_syswow  = wine_root + "/lib/wine/i386-windows";
    if (!IsDir(src_sys32)) {
        OH_LOG_ERROR(LOG_APP,
            "[wineprefix] missing %{public}s", src_sys32.c_str());
        return false;
    }

    // ---- 2. 建目录骨架 ----
    //
    // 设计:
    //   - 内容全部放在 drive_c/ 下 (wine 的约定)
    //   - dosdevices/c: 故意不建. box64 内置 patch 会把 wine 访问的
    //     "{prefix}/dosdevices/c:" 路径 remap 到 "{prefix}/drive_c",
    //     所以 wine 通过 dosdevices 路径也能正确命中.
    //   - 这避免了 wineboot 试图 symlink dosdevices/c: -> drive_c 时
    //     被 HAP 沙箱拒绝.
    const std::string drive_c    = wineprefix + "/drive_c";
    const std::string sys32      = drive_c + "/windows/system32";
    const std::string syswow64   = drive_c + "/windows/syswow64";
    const std::string fonts      = drive_c + "/windows/Fonts";

    const std::vector<std::string> dirs = {
        wineprefix,
        drive_c,
        drive_c + "/windows",
        sys32,
        syswow64,
        fonts,
        drive_c + "/users",
        drive_c + "/users/Public",
        drive_c + "/ProgramData",
        drive_c + "/Program Files",
        drive_c + "/Program Files (x86)",
        // dosdevices 目录本身可建可不建. 建一个空的避免 wine 报错.
        wineprefix + "/dosdevices",
    };
    for (const auto& d : dirs) {
        if (!MkdirP(d)) return false;
    }

    // ---- 3. 拷贝 64-bit PE DLL ----
    CopyStat s64 = CopyDirPE(src_sys32, sys32);
    if (s64.copied + s64.skipped < 5) {
        OH_LOG_ERROR(LOG_APP,
            "[wineprefix] only %{public}d files in system32, aborting",
            s64.copied + s64.skipped);
        return false;
    }

    // ---- 4. 拷贝 32-bit (可选) ----
    if (IsDir(src_syswow)) {
        CopyDirPE(src_syswow, syswow64);
    } else {
        OH_LOG_INFO(LOG_APP, "[wineprefix] no 32-bit PE dir, skipping syswow64");
    }
    
    // ---- 4.5. 严格校验关键文件 ----
    struct CriticalFile { const char* name; off_t min_size; };
    static const CriticalFile kCritical[] = {
        {"ntdll.dll",     500 * 1024},
        {"kernel32.dll",  500 * 1024},
        {"kernelbase.dll",500 * 1024},
        {"user32.dll",    300 * 1024},
        {"wineboot.exe",   10 * 1024},
        {"cmd.exe",        10 * 1024},
        {"start.exe",       5 * 1024},
    };
    int missing = 0;
    for (const auto& cf : kCritical) {
        std::string dst = sys32 + "/" + cf.name;
        off_t sz = FileSize(dst);
        if (sz < 0) {
            OH_LOG_ERROR(LOG_APP,
                "[wineprefix] CRITICAL MISSING: %{public}s", dst.c_str());
            missing++;
        } else if (sz < cf.min_size) {
            OH_LOG_ERROR(LOG_APP,
                "[wineprefix] CRITICAL TOO SMALL: %{public}s size=%{public}lld "
                "min=%{public}lld (likely .so wrapper, not real PE)",
                dst.c_str(), (long long)sz, (long long)cf.min_size);
            missing++;
        } else {
            OH_LOG_INFO(LOG_APP,
                "[wineprefix] critical OK: %{public}s size=%{public}lld",
                cf.name, (long long)sz);
        }
    }
    if (missing > 0) {
        OH_LOG_ERROR(LOG_APP,
            "[wineprefix] %{public}d critical files missing/bad, aborting setup",
            missing);
        return false;
    }

    // ---- 5. 写标记 ----
    if (!WriteMarker(marker)) {
        OH_LOG_WARN(LOG_APP, "[wineprefix] write marker failed (non-fatal)");
    }

    OH_LOG_INFO(LOG_APP, "[wineprefix] setup done");
    return true;
}

// ============================================================
// NAPI 包装
// ============================================================

napi_value SetupWinePrefixNapi(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string prefix    = napiutil::GetStringArg(env, args[0]);
    std::string wine_root = napiutil::GetStringArg(env, args[1]);

    bool ok = SetupWinePrefix(prefix, wine_root);

    napi_value r;
    napi_get_boolean(env, ok, &r);
    return r;
}

}  // namespace wineprefix