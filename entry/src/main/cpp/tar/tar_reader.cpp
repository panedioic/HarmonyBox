#include "tar_reader.h"
#include "tar_format.h"

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <utime.h>
#include <vector>

#undef LOG_TAG
#define LOG_TAG "HBox_Tar"
#include <hilog/log.h>

namespace tar {

namespace {

int64_t ParseOctal(const char* s, size_t n) {
    int64_t v = 0;
    for (size_t i = 0; i < n; ++i) {
        char c = s[i];
        if (c == 0 || c == ' ') break;
        if (c < '0' || c > '7') return -1;
        v = v * 8 + (c - '0');
    }
    return v;
}

bool IsAllZero(const RawHeader& h) {
    const char* p = reinterpret_cast<const char*>(&h);
    for (size_t i = 0; i < kBlockSize; ++i) if (p[i] != 0) return false;
    return true;
}

bool ChecksumOk(const RawHeader& h) {
    unsigned sum = 0;
    const unsigned char* p = reinterpret_cast<const unsigned char*>(&h);
    for (size_t i = 0; i < kBlockSize; ++i) {
        if (i >= offsetof(RawHeader, chksum) &&
            i <  offsetof(RawHeader, chksum) + sizeof(h.chksum)) {
            sum += ' ';
        } else {
            sum += p[i];
        }
    }
    int64_t recorded = ParseOctal(h.chksum, sizeof(h.chksum));
    return recorded >= 0 && (unsigned)recorded == sum;
}

std::string FieldToString(const char* buf, size_t n) {
    size_t len = 0;
    while (len < n && buf[len] != 0) ++len;
    return std::string(buf, len);
}

std::string BuildEntryName(const RawHeader& h) {
    std::string prefix = FieldToString(h.prefix, sizeof(h.prefix));
    std::string name   = FieldToString(h.name,   sizeof(h.name));
    if (!prefix.empty()) return prefix + "/" + name;
    return name;
}

// 判 dest+"/"+entry 是否会跳出 dest。用字符串比较, 假设两者都是清洁路径。
bool IsPathInside(const std::string& dest_abs, const std::string& target_abs) {
    if (target_abs.size() < dest_abs.size()) return false;
    if (target_abs.compare(0, dest_abs.size(), dest_abs) != 0) return false;
    if (target_abs.size() == dest_abs.size()) return true;
    return target_abs[dest_abs.size()] == '/';
}

// 拼接 dest/entry, 拒绝: 绝对路径, 含 ".." 段, 空路径
// 返回空串表示拒绝
std::string ResolveSafeTarget(const std::string& dest_dir,
                              const std::string& entry_name) {
    if (entry_name.empty()) return "";
    if (entry_name[0] == '/') return "";     // 绝对路径拒绝
    // 逐段检查 ..
    size_t i = 0;
    while (i < entry_name.size()) {
        size_t j = entry_name.find('/', i);
        if (j == std::string::npos) j = entry_name.size();
        std::string seg = entry_name.substr(i, j - i);
        if (seg == "..") return "";
        i = j + 1;
    }
    std::string tgt = dest_dir;
    if (!tgt.empty() && tgt.back() != '/') tgt += '/';
    tgt += entry_name;
    return tgt;
}

bool MkdirRecursive(const std::string& path, mode_t mode) {
    if (path.empty()) return false;
    struct stat st;
    if (stat(path.c_str(), &st) == 0) return S_ISDIR(st.st_mode);
    size_t slash = path.rfind('/');
    if (slash != std::string::npos && slash > 0) {
        std::string parent = path.substr(0, slash);
        if (!MkdirRecursive(parent, mode)) return false;
    }
    if (mkdir(path.c_str(), mode) == 0) return true;
    return errno == EEXIST;
}

bool EnsureParentDir(const std::string& file_path) {
    size_t slash = file_path.rfind('/');
    if (slash == std::string::npos) return true;
    return MkdirRecursive(file_path.substr(0, slash), 0755);
}

}  // anonymous namespace

ExtractResult Extract(const std::string& archive, const std::string& dest_dir) {
    ExtractResult r;
    int fd = open(archive.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        r.error = std::string("open archive: ") + strerror(errno);
        return r;
    }

    // 保证 dest 存在
    if (!MkdirRecursive(dest_dir, 0755)) {
        r.error = "cannot create dest_dir";
        close(fd);
        return r;
    }

    // 缓存 GNU LongName / LongLink 的名字
    std::string pending_longname;
    std::string pending_longlink;
    int zero_blocks_in_a_row = 0;

    while (true) {
        RawHeader hdr;
        ssize_t got = read(fd, &hdr, kBlockSize);
        if (got == 0) break;
        if (got != (ssize_t)kBlockSize) {
            r.error = "unexpected EOF in header";
            close(fd);
            return r;
        }
        if (IsAllZero(hdr)) {
            zero_blocks_in_a_row++;
            if (zero_blocks_in_a_row >= 2) break;  // 双零块=归档结束
            continue;
        }
        zero_blocks_in_a_row = 0;

        if (!ChecksumOk(hdr)) {
            r.error = "header checksum mismatch";
            close(fd);
            return r;
        }

        int64_t size = ParseOctal(hdr.size, sizeof(hdr.size));
        if (size < 0) {
            r.error = "bad size field";
            close(fd);
            return r;
        }
        int64_t padded = (size + kBlockSize - 1) & ~(int64_t)(kBlockSize - 1);
        char type = hdr.typeflag;

        // 处理 GNU 长名头: 下一个数据块就是长名字, 覆盖 pending_*
        if (type == kTypeGnuLongName || type == kTypeGnuLongLink) {
            std::vector<char> buf(padded);
            if (read(fd, buf.data(), padded) != padded) {
                r.error = "eof in long name payload";
                close(fd);
                return r;
            }
            std::string name(buf.data(), (size_t)size);
            // 去掉尾部 NUL
            while (!name.empty() && name.back() == '\0') name.pop_back();
            if (type == kTypeGnuLongName) pending_longname = name;
            else                          pending_longlink = name;
            continue;
        }

        // 组装 entry name
        std::string entry_name = !pending_longname.empty()
            ? pending_longname
            : BuildEntryName(hdr);
        std::string linkname = !pending_longlink.empty()
            ? pending_longlink
            : FieldToString(hdr.linkname, sizeof(hdr.linkname));
        pending_longname.clear();
        pending_longlink.clear();

        // 目录名末尾可能有 /, 保留
        std::string safe_name = entry_name;
        if (!safe_name.empty() && safe_name.back() == '/') safe_name.pop_back();

        std::string target = ResolveSafeTarget(dest_dir, safe_name);
        if (target.empty()) {
            OH_LOG_WARN(LOG_APP, "tar: reject unsafe entry '%{public}s'",
                        entry_name.c_str());
            r.skipped++;
            // 跳过数据部分
            if (padded > 0) lseek(fd, padded, SEEK_CUR);
            continue;
        }

        int64_t mode = ParseOctal(hdr.mode, sizeof(hdr.mode));
        if (mode < 0) mode = 0644;

        if (type == kTypeDirectory) {
            if (!MkdirRecursive(target, mode & 0777 ? mode & 0777 : 0755)) {
                r.error = "mkdir failed: " + target + ": " + strerror(errno);
                close(fd);
                return r;
            }
            r.extracted++;
        } else if (type == kTypeRegular || type == kTypeRegularOld
                   || type == kTypeContiguous) {
            if (!EnsureParentDir(target)) {
                r.error = "cannot create parent for: " + target;
                close(fd);
                return r;
            }
            int outfd = open(target.c_str(),
                             O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
                             mode & 0777);
            if (outfd < 0) {
                r.error = "open '" + target + "': " + strerror(errno);
                close(fd);
                return r;
            }
            int64_t remain = size;
            char buf[64 * 1024];
            while (remain > 0) {
                size_t want = remain > (int64_t)sizeof(buf)
                              ? sizeof(buf) : (size_t)remain;
                ssize_t n = read(fd, buf, want);
                if (n <= 0) {
                    r.error = "eof in file payload: " + target;
                    close(outfd);
                    close(fd);
                    return r;
                }
                ssize_t w = write(outfd, buf, n);
                if (w != n) {
                    r.error = "write '" + target + "': " + strerror(errno);
                    close(outfd);
                    close(fd);
                    return r;
                }
                remain -= n;
            }
            close(outfd);
            // 消耗 padding
            int64_t pad = padded - size;
            if (pad > 0) lseek(fd, pad, SEEK_CUR);
            r.extracted++;
        } else if (type == kTypeSymlink) {
            if (!EnsureParentDir(target)) {
                r.error = "cannot create parent for symlink: " + target;
                close(fd);
                return r;
            }
            unlink(target.c_str());  // 覆盖旧的
            if (symlink(linkname.c_str(), target.c_str()) != 0) {
                OH_LOG_WARN(LOG_APP,
                    "tar: symlink '%{public}s' -> '%{public}s' failed: %{public}s",
                    target.c_str(), linkname.c_str(), strerror(errno));
                r.skipped++;
            } else {
                r.extracted++;
            }
            // symlink 无 payload, size 应为 0
            if (padded > 0) lseek(fd, padded, SEEK_CUR);
        } else {
            // 硬链接 / char / block / fifo 全跳过
            OH_LOG_WARN(LOG_APP, "tar: skip type '%{public}c' entry '%{public}s'",
                        type, entry_name.c_str());
            r.skipped++;
            if (padded > 0) lseek(fd, padded, SEEK_CUR);
        }
    }

    close(fd);
    r.ok = true;
    return r;
}

}  // namespace tar