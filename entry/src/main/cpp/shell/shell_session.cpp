#include "shell_session.h"

#include <algorithm>
#include <cstring>
#include <ctime>
#include <vector>

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <hilog/log.h>

#undef LOG_TAG
#define LOG_TAG "HBox_NAPI_Shell_SSession"

namespace shell {

namespace {
constexpr unsigned char ESC = 0x1b;
constexpr unsigned char BEL = 0x07;
}

bool ShellSession::Init(const std::string& log_dir) {
    if (log_dir.empty()) {
        OH_LOG_WARN(LOG_APP, "shell session: empty log_dir, skip");
        return false;
    }

    // 确保目录存在 (递归一级即可)
    if (mkdir(log_dir.c_str(), 0700) != 0 && errno != EEXIST) {
        OH_LOG_WARN(LOG_APP, "mkdir %{public}s failed: %{public}s",
                    log_dir.c_str(), strerror(errno));
        return false;
    }

    RotateLogs(log_dir, kMaxLogs);

    std::string ts = MakeTimestamp();
    log_path_ = log_dir + "/session-" + ts + ".log";
    log_fd_ = open(log_path_.c_str(),
                   O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
                   0600);
    if (log_fd_ < 0) {
        OH_LOG_ERROR(LOG_APP, "open log %{public}s failed: %{public}s",
                     log_path_.c_str(), strerror(errno));
        log_path_.clear();
        return false;
    }
    ansi_state_ = 0;

    std::string header = "=== HarmonyBox Shell Session " + ts + " ===\n";
    WriteRaw(header.data(), header.size());

    OH_LOG_INFO(LOG_APP, "shell session log: %{public}s", log_path_.c_str());
    return true;
}

void ShellSession::Shutdown() {
    if (log_fd_ < 0) return;
    const char* footer = "=== session end ===\n";
    WriteRaw(footer, strlen(footer));
    fsync(log_fd_);
    close(log_fd_);
    log_fd_ = -1;
    ansi_state_ = 0;
}

void ShellSession::Append(const std::string& data) {
    if (log_fd_ < 0 || data.empty()) return;
    WriteStripped(data);
}

void ShellSession::AppendDirect(const std::string& line) {
    if (log_fd_ < 0 || line.empty()) return;
    WriteRaw(line.data(), line.size());
}

void ShellSession::Flush() {
    if (log_fd_ >= 0) fsync(log_fd_);
}

void ShellSession::WriteRaw(const char* data, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(log_fd_, data + off, len - off);
        if (n > 0) { off += (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        // 写失败, best effort, 关掉防止刷屏报错
        OH_LOG_WARN(LOG_APP, "shell log write failed: %{public}s", strerror(errno));
        close(log_fd_);
        log_fd_ = -1;
        return;
    }
}

void ShellSession::WriteStripped(const std::string& data) {
    // ANSI / 控制序列状态机:
    //   0: 普通
    //   1: 收到 ESC
    //   2: CSI (ESC [), 跳到 final byte (0x40-0x7E)
    //   3: SS3 (ESC O), 跳一个字节
    //   4: OSC (ESC ]), 跳到 BEL 或 ESC
    std::string out;
    out.reserve(data.size());
    for (size_t i = 0; i < data.size(); ++i) {
        unsigned char c = (unsigned char)data[i];
        switch (ansi_state_) {
            case 0:
                if (c == ESC) { ansi_state_ = 1; }
                else if (c == '\r') { /* 终端用 \r\n, 文件只要 \n */ }
                else { out.push_back((char)c); }
                break;
            case 1:
                if      (c == '[') ansi_state_ = 2;
                else if (c == 'O') ansi_state_ = 3;
                else if (c == ']') ansi_state_ = 4;
                else                ansi_state_ = 0;  // 未知, 丢
                break;
            case 2:
                if (c >= 0x40 && c <= 0x7e) ansi_state_ = 0;
                // 否则停在 state 2 (CSI 中间字节)
                break;
            case 3:
                ansi_state_ = 0;
                break;
            case 4:
                if (c == BEL) ansi_state_ = 0;
                else if (c == ESC) ansi_state_ = 1;  // 退回 ESC, ESC\ 结束 OSC
                break;
        }
    }
    if (!out.empty()) WriteRaw(out.data(), out.size());
}

void ShellSession::RotateLogs(const std::string& dir, int keep) {
    DIR* d = opendir(dir.c_str());
    if (!d) return;

    struct Entry { std::string name; time_t mtime; };
    std::vector<Entry> files;

    struct dirent* de;
    while ((de = readdir(d)) != nullptr) {
        std::string n = de->d_name;
        if (n == "." || n == "..") continue;
        if (n.size() < 12) continue;
        if (n.compare(0, 8, "session-") != 0) continue;
        if (n.size() < 4 || n.compare(n.size() - 4, 4, ".log") != 0) continue;

        std::string full = dir + "/" + n;
        struct stat st;
        if (stat(full.c_str(), &st) == 0) {
            files.push_back({n, st.st_mtime});
        }
    }
    closedir(d);

    if ((int)files.size() <= keep) return;

    std::sort(files.begin(), files.end(),
              [](const Entry& a, const Entry& b) { return a.mtime > b.mtime; });

    for (size_t i = (size_t)keep; i < files.size(); ++i) {
        std::string full = dir + "/" + files[i].name;
        if (unlink(full.c_str()) != 0) {
            OH_LOG_WARN(LOG_APP, "unlink old log %{public}s failed: %{public}s",
                        full.c_str(), strerror(errno));
        }
    }
}

std::string ShellSession::MakeTimestamp() {
    time_t t = time(nullptr);
    struct tm tm;
    localtime_r(&t, &tm);
    char buf[32];
    snprintf(buf, sizeof(buf), "%04d%02d%02d-%02d%02d%02d",
             tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
             tm.tm_hour, tm.tm_min, tm.tm_sec);
    return buf;
}

} // namespace shell