// tar/tar_writer.cpp
#include "tar_writer.h"
#include "tar_format.h"

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <string>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <vector>

#undef LOG_TAG
#define LOG_TAG "HBox_Tar"
#include <hilog/log.h>

namespace tar {

namespace {

// 写 octal 到定长字段, 尾部一定是 NUL
void WriteOctal(char* dst, size_t n, int64_t v) {
    char buf[32];
    snprintf(buf, sizeof(buf), "%0*llo", (int)(n - 1), (unsigned long long)v);
    memcpy(dst, buf, n - 1);
    dst[n - 1] = 0;
}

void ComputeChecksum(RawHeader& h) {
    memset(h.chksum, ' ', sizeof(h.chksum));
    unsigned sum = 0;
    const unsigned char* p = reinterpret_cast<unsigned char*>(&h);
    for (size_t i = 0; i < kBlockSize; ++i) sum += p[i];
    // 6 位 octal + NUL + space
    char buf[8];
    snprintf(buf, sizeof(buf), "%06o", sum);
    memcpy(h.chksum, buf, 6);
    h.chksum[6] = 0;
    h.chksum[7] = ' ';
}

bool SplitPathForUstar(const std::string& path,
                       std::string* name_out, std::string* prefix_out) {
    if (path.size() <= 100) {
        *name_out = path;
        prefix_out->clear();
        return true;
    }
    if (path.size() > 100 + 1 + 155) return false;
    for (size_t split = std::min<size_t>(155, path.size() - 1);
         split > 0; --split) {
        if (path[split] != '/') continue;
        std::string prefix = path.substr(0, split);
        std::string name = path.substr(split + 1);
        if (name.size() <= 100 && prefix.size() <= 155 && !name.empty()) {
            *name_out = name;
            *prefix_out = prefix;
            return true;
        }
    }
    return false;
}

void FillHeader(RawHeader& h, const std::string& name, const std::string& prefix,
                mode_t mode, int64_t size, time_t mtime, char typeflag,
                const std::string& linkname) {
    memset(&h, 0, sizeof(h));
    strncpy(h.name, name.c_str(), sizeof(h.name));
    if (!prefix.empty()) strncpy(h.prefix, prefix.c_str(), sizeof(h.prefix));
    WriteOctal(h.mode,  sizeof(h.mode),  mode & 07777);
    WriteOctal(h.uid,   sizeof(h.uid),   0);
    WriteOctal(h.gid,   sizeof(h.gid),   0);
    WriteOctal(h.size,  sizeof(h.size),  size);
    WriteOctal(h.mtime, sizeof(h.mtime), (int64_t)mtime);
    h.typeflag = typeflag;
    if (!linkname.empty()) {
        strncpy(h.linkname, linkname.c_str(), sizeof(h.linkname));
    }
    memcpy(h.magic, "ustar\0", 6);
    memcpy(h.version, "00", 2);
    ComputeChecksum(h);
}

class Writer {
public:
    explicit Writer(int fd) : fd_(fd) {}
    bool WriteAll(const void* data, size_t n) {
        const char* p = static_cast<const char*>(data);
        size_t off = 0;
        while (off < n) {
            ssize_t w = write(fd_, p + off, n - off);
            if (w < 0) {
                if (errno == EINTR) continue;
                return false;
            }
            off += (size_t)w;
        }
        return true;
    }
    bool WritePadding(size_t data_size) {
        size_t rem = data_size % kBlockSize;
        if (rem == 0) return true;
        char pad[kBlockSize] = {0};
        return WriteAll(pad, kBlockSize - rem);
    }
private:
    int fd_;
};

bool WriteEntryHeader(Writer& w, const std::string& entry_path,
                      const struct stat& st, char typeflag,
                      const std::string& linkname) {
    std::string name, prefix;
    if (!SplitPathForUstar(entry_path, &name, &prefix)) {
        OH_LOG_WARN(LOG_APP, "tar: skip too-long path '%{public}s'",
                    entry_path.c_str());
        return false;
    }
    RawHeader h;
    int64_t size = (typeflag == kTypeRegular) ? (int64_t)st.st_size : 0;
    FillHeader(h, name, prefix, st.st_mode, size, st.st_mtime,
               typeflag, linkname);
    return w.WriteAll(&h, sizeof(h));
}

bool WriteRegular(Writer& w, const std::string& full_path,
                  const std::string& entry_path, const struct stat& st) {
    if (!WriteEntryHeader(w, entry_path, st, kTypeRegular, "")) return false;
    int fd = open(full_path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) return false;
    char buf[64 * 1024];
    int64_t total = 0;
    while (true) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n == 0) break;
        if (n < 0) {
            if (errno == EINTR) continue;
            close(fd);
            return false;
        }
        if (!w.WriteAll(buf, (size_t)n)) { close(fd); return false; }
        total += n;
        if (total >= st.st_size) break;
    }
    close(fd);
    if (!w.WritePadding((size_t)st.st_size)) return false;
    return true;
}

bool WriteDirectory(Writer& w, const std::string& entry_path,
                    const struct stat& st) {
    std::string with_slash = entry_path;
    if (with_slash.empty() || with_slash.back() != '/') with_slash += '/';
    return WriteEntryHeader(w, with_slash, st, kTypeDirectory, "");
}

bool WriteSymlink(Writer& w, const std::string& full_path,
                  const std::string& entry_path, const struct stat& st) {
    char lbuf[4096];
    ssize_t n = readlink(full_path.c_str(), lbuf, sizeof(lbuf) - 1);
    if (n < 0) return false;
    lbuf[n] = 0;
    if ((size_t)n > 100) {
        OH_LOG_WARN(LOG_APP, "tar: skip too-long symlink '%{public}s'",
                    entry_path.c_str());
        return false;
    }
    return WriteEntryHeader(w, entry_path, st, kTypeSymlink,
                            std::string(lbuf, n));
}

bool WalkAndPack(Writer& w, const std::string& src_root,
                 const std::string& rel_path, CreateResult& r) {
    std::string full = src_root;
    if (!rel_path.empty()) full += "/" + rel_path;
    struct stat st;
    if (lstat(full.c_str(), &st) != 0) return false;

    if (S_ISDIR(st.st_mode)) {
        if (!rel_path.empty()) {
            if (WriteDirectory(w, rel_path, st)) r.included++;
            else r.skipped++;
        }
        DIR* dir = opendir(full.c_str());
        if (!dir) return false;
        std::vector<std::string> names;
        struct dirent* de;
        while ((de = readdir(dir)) != nullptr) {
            std::string n = de->d_name;
            if (n == "." || n == "..") continue;
            names.push_back(n);
        }
        closedir(dir);
        std::sort(names.begin(), names.end());
        for (const auto& n : names) {
            std::string sub = rel_path.empty() ? n : (rel_path + "/" + n);
            WalkAndPack(w, src_root, sub, r);
        }
        return true;
    }

    if (S_ISREG(st.st_mode)) {
        if (WriteRegular(w, full, rel_path, st)) r.included++;
        else r.skipped++;
        return true;
    }

    if (S_ISLNK(st.st_mode)) {
        if (WriteSymlink(w, full, rel_path, st)) r.included++;
        else r.skipped++;
        return true;
    }

    OH_LOG_WARN(LOG_APP, "tar: skip unsupported type: %{public}s", full.c_str());
    r.skipped++;
    return true;
}

CreateResult CreateCore(int fd, const std::string& src_dir) {
    CreateResult r;
    struct stat st;
    if (stat(src_dir.c_str(), &st) != 0 || !S_ISDIR(st.st_mode)) {
        r.error = "src_dir not a directory: " + src_dir;
        return r;
    }
    Writer w(fd);
    WalkAndPack(w, src_dir, "", r);
    // 双零块结束标记
    char zeros[kBlockSize * 2] = {0};
    w.WriteAll(zeros, sizeof(zeros));
    r.ok = true;
    return r;
}

}  // anonymous namespace

// ==============================================================
// public
// ==============================================================
CreateResult Create(const std::string& archive, const std::string& src_dir) {
    int fd = open(archive.c_str(),
                  O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) {
        CreateResult r;
        r.error = std::string("open archive: ") + strerror(errno);
        return r;
    }
    CreateResult r = CreateCore(fd, src_dir);
    close(fd);
    return r;
}

CreateResult CreateToFd(int fd, const std::string& src_dir) {
    if (fd < 0) {
        CreateResult r;
        r.error = "invalid fd";
        return r;
    }
    return CreateCore(fd, src_dir);
}

}  // namespace tar