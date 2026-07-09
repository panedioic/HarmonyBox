#include "tar_reader.h"
#include "tar_format.h"

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
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

std::string ResolveSafeTarget(const std::string& dest_dir,
                              const std::string& entry_name) {
    if (entry_name.empty()) return "";
    if (entry_name[0] == '/') return "";
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

// 有边界的 fd Reader
class BoundedReader {
public:
    BoundedReader(int fd, int64_t start, int64_t length)
        : fd_(fd), length_(length), cursor_(0) {
        // 起始定位
        if (start != 0) lseek(fd_, start, SEEK_SET);
    }

    // 读满 n 字节, 返回是否成功
    bool ReadExact(void* buf, size_t n) {
        if (!CanRead((int64_t)n)) return false;
        char* p = static_cast<char*>(buf);
        size_t off = 0;
        while (off < n) {
            ssize_t r = read(fd_, p + off, n - off);
            if (r == 0) return false;
            if (r < 0) {
                if (errno == EINTR) continue;
                return false;
            }
            off += (size_t)r;
            cursor_ += r;
        }
        return true;
    }

    // 尝试读 n, 返回实际读到的字节
    ssize_t ReadSome(void* buf, size_t n) {
        if (length_ >= 0) {
            int64_t remain = length_ - cursor_;
            if (remain <= 0) return 0;
            if ((int64_t)n > remain) n = (size_t)remain;
        }
        ssize_t r = read(fd_, buf, n);
        if (r > 0) cursor_ += r;
        return r;
    }

    bool Skip(int64_t n) {
        if (n <= 0) return true;
        if (length_ >= 0 && cursor_ + n > length_) return false;
        if (lseek(fd_, n, SEEK_CUR) < 0) return false;
        cursor_ += n;
        return true;
    }

    bool AtEnd() const {
        return length_ >= 0 && cursor_ >= length_;
    }

private:
    bool CanRead(int64_t n) const {
        if (length_ < 0) return true;
        return cursor_ + n <= length_;
    }
    int fd_;
    int64_t length_;
    int64_t cursor_;
};

// 核心解压逻辑, 只依赖 BoundedReader
ExtractResult ExtractCore(BoundedReader& reader, const std::string& dest_dir) {
    ExtractResult r;

    if (!MkdirRecursive(dest_dir, 0755)) {
        r.error = "cannot create dest_dir";
        return r;
    }

    std::string pending_longname;
    std::string pending_longlink;
    int zero_blocks = 0;

    while (true) {
        RawHeader hdr;
        // 读一个 block; EOF 表示归档结束
        if (reader.AtEnd()) break;
        ssize_t got = reader.ReadSome(&hdr, kBlockSize);
        if (got == 0) break;
        if (got != (ssize_t)kBlockSize) {
            // 需要补齐
            if (!reader.ReadExact(reinterpret_cast<char*>(&hdr) + got,
                                  kBlockSize - got)) {
                r.error = "unexpected EOF in header";
                return r;
            }
        }

        if (IsAllZero(hdr)) {
            zero_blocks++;
            if (zero_blocks >= 2) break;
            continue;
        }
        zero_blocks = 0;

        if (!ChecksumOk(hdr)) {
            r.error = "header checksum mismatch";
            return r;
        }

        int64_t size = ParseOctal(hdr.size, sizeof(hdr.size));
        if (size < 0) { r.error = "bad size field"; return r; }
        int64_t padded = (size + kBlockSize - 1) & ~(int64_t)(kBlockSize - 1);
        char type = hdr.typeflag;

        if (type == kTypeGnuLongName || type == kTypeGnuLongLink) {
            std::vector<char> buf((size_t)padded);
            if (!reader.ReadExact(buf.data(), (size_t)padded)) {
                r.error = "eof in long name payload";
                return r;
            }
            std::string name(buf.data(), (size_t)size);
            while (!name.empty() && name.back() == '\0') name.pop_back();
            if (type == kTypeGnuLongName) pending_longname = name;
            else                          pending_longlink = name;
            continue;
        }

        std::string entry_name = !pending_longname.empty()
            ? pending_longname : BuildEntryName(hdr);
        std::string linkname = !pending_longlink.empty()
            ? pending_longlink
            : FieldToString(hdr.linkname, sizeof(hdr.linkname));
        pending_longname.clear();
        pending_longlink.clear();

        std::string safe_name = entry_name;
        if (!safe_name.empty() && safe_name.back() == '/') safe_name.pop_back();

        std::string target = ResolveSafeTarget(dest_dir, safe_name);
        if (target.empty()) {
            OH_LOG_WARN(LOG_APP, "tar: reject unsafe '%{public}s'",
                        entry_name.c_str());
            r.skipped++;
            if (padded > 0) reader.Skip(padded);
            continue;
        }

        int64_t mode = ParseOctal(hdr.mode, sizeof(hdr.mode));
        if (mode < 0) mode = 0644;

        if (type == kTypeDirectory) {
            if (!MkdirRecursive(target, mode & 0777 ? mode & 0777 : 0755)) {
                r.error = "mkdir failed: " + target + ": " + strerror(errno);
                return r;
            }
            r.extracted++;
        } else if (type == kTypeRegular || type == kTypeRegularOld
                   || type == kTypeContiguous) {
            if (!EnsureParentDir(target)) {
                r.error = "cannot create parent for: " + target;
                return r;
            }
            int outfd = open(target.c_str(),
                             O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
                             mode & 0777);
            if (outfd < 0) {
                r.error = "open '" + target + "': " + strerror(errno);
                return r;
            }
            int64_t remain = size;
            char buf[64 * 1024];
            while (remain > 0) {
                size_t want = remain > (int64_t)sizeof(buf)
                              ? sizeof(buf) : (size_t)remain;
                ssize_t n = reader.ReadSome(buf, want);
                if (n <= 0) {
                    r.error = "eof in file: " + target;
                    close(outfd);
                    return r;
                }
                ssize_t w = write(outfd, buf, n);
                if (w != n) {
                    r.error = "write '" + target + "': " + strerror(errno);
                    close(outfd);
                    return r;
                }
                remain -= n;
            }
            close(outfd);
            int64_t pad = padded - size;
            if (pad > 0) reader.Skip(pad);
            r.extracted++;
        } else if (type == kTypeSymlink) {
            if (!EnsureParentDir(target)) {
                r.error = "cannot create parent for symlink: " + target;
                return r;
            }
            unlink(target.c_str());
            if (symlink(linkname.c_str(), target.c_str()) != 0) {
                OH_LOG_WARN(LOG_APP,
                    "tar: symlink '%{public}s' -> '%{public}s' failed: %{public}s",
                    target.c_str(), linkname.c_str(), strerror(errno));
                r.skipped++;
            } else {
                r.extracted++;
            }
            if (padded > 0) reader.Skip(padded);
        } else {
            OH_LOG_WARN(LOG_APP, "tar: skip type '%{public}c' entry '%{public}s'",
                        type, entry_name.c_str());
            r.skipped++;
            if (padded > 0) reader.Skip(padded);
        }
    }

    r.ok = true;
    return r;
}

}  // anonymous namespace

ExtractResult Extract(const std::string& archive, const std::string& dest_dir) {
    ExtractResult r;
    int fd = open(archive.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        r.error = std::string("open archive: ") + strerror(errno);
        return r;
    }
    BoundedReader reader(fd, 0, -1);
    r = ExtractCore(reader, dest_dir);
    close(fd);
    return r;
}

ExtractResult ExtractFromFd(int fd, int64_t offset, int64_t length,
                            const std::string& dest_dir) {
    ExtractResult r;
    if (fd < 0) { r.error = "invalid fd"; return r; }
    BoundedReader reader(fd, offset, length);
    return ExtractCore(reader, dest_dir);
}

}  // namespace tar