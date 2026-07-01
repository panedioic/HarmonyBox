#include "shell_env.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <hilog/log.h>

#undef LOG_TAG
#define LOG_TAG "HBox_NAPI_Shell_SEnv"

namespace shell {

namespace {

// 简易 K=V 行解析. 允许 val 含 = 和空格. 不做转义.
// 注释: 以 # 开头的行跳过
bool ParseLine(const std::string& line, std::string* k, std::string* v) {
    if (line.empty() || line[0] == '#') return false;
    size_t eq = line.find('=');
    if (eq == std::string::npos || eq == 0) return false;
    *k = line.substr(0, eq);
    *v = line.substr(eq + 1);
    return true;
}

bool IsValidKey(const std::string& k) {
    if (k.empty()) return false;
    char c0 = k[0];
    if (!((c0 >= 'A' && c0 <= 'Z') || (c0 >= 'a' && c0 <= 'z') || c0 == '_'))
        return false;
    for (char c : k) {
        bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                  (c >= '0' && c <= '9') || c == '_';
        if (!ok) return false;
    }
    return true;
}

} // anonymous namespace

void ShellEnv::Init(const std::string& persist_path) {
    persist_path_ = persist_path;
    system_vars_.clear();
    shell_vars_.clear();
    persistent_keys_.clear();
    readonly_keys_.clear();
    LoadPersist();
}

void ShellEnv::SetSystemVar(const std::string& key, const std::string& val) {
    if (!IsValidKey(key)) return;
    system_vars_[key] = val;
}

void ShellEnv::AddReadonly(const std::string& key) {
    readonly_keys_.insert(key);
}

int ShellEnv::Set(const std::string& key, const std::string& val, bool persistent) {
    if (!IsValidKey(key)) return 1;
    if (readonly_keys_.count(key)) return 1;

    shell_vars_[key] = val;
    if (persistent) {
        persistent_keys_.insert(key);
        if (!SavePersist()) return 2;
    } else {
        // 非持久化 set 时, 若之前是 persistent, 保留 persistent 标记
        // 只有显式 -p 移除或 unset 才清
    }
    return 0;
}

int ShellEnv::Unset(const std::string& key, bool persistent) {
    if (readonly_keys_.count(key)) return 1;
    shell_vars_.erase(key);
    bool was_persistent = persistent_keys_.erase(key) > 0;
    if (persistent || was_persistent) {
        if (!SavePersist()) return 2;
    }
    return 0;
}

bool ShellEnv::Has(const std::string& key) const {
    return shell_vars_.count(key) > 0 || system_vars_.count(key) > 0;
}

std::string ShellEnv::Get(const std::string& key) const {
    auto it = shell_vars_.find(key);
    if (it != shell_vars_.end()) return it->second;
    auto it2 = system_vars_.find(key);
    if (it2 != system_vars_.end()) return it2->second;
    return {};
}

bool ShellEnv::IsReadonly(const std::string& key) const {
    return readonly_keys_.count(key) > 0;
}

bool ShellEnv::IsPersistent(const std::string& key) const {
    return persistent_keys_.count(key) > 0;
}

std::vector<ShellEnv::Entry> ShellEnv::All() const {
    // union of system + shell keys
    std::unordered_map<std::string, std::string> merged;
    for (auto& kv : system_vars_) merged[kv.first] = kv.second;
    for (auto& kv : shell_vars_)  merged[kv.first] = kv.second;

    std::vector<Entry> out;
    out.reserve(merged.size());
    for (auto& kv : merged) {
        Entry e;
        e.key = kv.first;
        e.val = kv.second;
        e.readonly = readonly_keys_.count(kv.first) > 0;
        e.persistent = persistent_keys_.count(kv.first) > 0;
        out.push_back(std::move(e));
    }
    std::sort(out.begin(), out.end(),
              [](const Entry& a, const Entry& b) { return a.key < b.key; });
    return out;
}

std::vector<std::string> ShellEnv::BuildEnvArray() const {
    std::unordered_map<std::string, std::string> merged;
    for (auto& kv : system_vars_) merged[kv.first] = kv.second;
    for (auto& kv : shell_vars_)  merged[kv.first] = kv.second;  // 覆盖
    std::vector<std::string> out;
    out.reserve(merged.size());
    for (auto& kv : merged) {
        out.push_back(kv.first + "=" + kv.second);
    }
    return out;
}

void ShellEnv::LoadPersist() {
    if (persist_path_.empty()) return;
    FILE* f = fopen(persist_path_.c_str(), "r");
    if (!f) return;

    char buf[4096];
    while (fgets(buf, sizeof(buf), f)) {
        std::string line = buf;
        while (!line.empty() &&
               (line.back() == '\n' || line.back() == '\r' || line.back() == ' ')) {
            line.pop_back();
        }
        std::string k, v;
        if (!ParseLine(line, &k, &v)) continue;
        if (!IsValidKey(k)) continue;
        shell_vars_[k] = v;
        persistent_keys_.insert(k);
    }
    fclose(f);
    OH_LOG_INFO(LOG_APP, "shell env loaded %{public}d persistent vars",
                (int)persistent_keys_.size());
}

bool ShellEnv::SavePersist() {
    if (persist_path_.empty()) return true;

    std::string tmp = persist_path_ + ".tmp";
    int fd = open(tmp.c_str(),
                  O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
                  0600);
    if (fd < 0) {
        OH_LOG_WARN(LOG_APP, "shell env open tmp failed: %{public}s",
                    strerror(errno));
        return false;
    }
    const char* header =
        "# auto-managed by hbsh, do not edit while shell is running\n";
    (void)write(fd, header, strlen(header));

    // 只落 persistent 的 shell vars
    std::vector<std::pair<std::string, std::string>> sorted;
    for (auto& kv : shell_vars_) {
        if (persistent_keys_.count(kv.first)) sorted.push_back(kv);
    }
    std::sort(sorted.begin(), sorted.end(),
              [](const std::pair<std::string, std::string>& a,
                 const std::pair<std::string, std::string>& b) {
                  return a.first < b.first;
              });

    for (auto& kv : sorted) {
        std::string line = kv.first + "=" + kv.second + "\n";
        if (write(fd, line.data(), line.size()) < 0) {
            close(fd);
            unlink(tmp.c_str());
            return false;
        }
    }
    if (fsync(fd) != 0) {
        OH_LOG_WARN(LOG_APP, "shell env fsync failed: %{public}s", strerror(errno));
    }
    close(fd);
    if (rename(tmp.c_str(), persist_path_.c_str()) != 0) {
        OH_LOG_WARN(LOG_APP, "shell env rename failed: %{public}s", strerror(errno));
        unlink(tmp.c_str());
        return false;
    }
    return true;
}

} // namespace shell