#include "shell_dispatcher.h"
#include <algorithm>

namespace shell {

ShellDispatcher::~ShellDispatcher() {
    ReleaseAllExternal();
}

void ShellDispatcher::RegisterBuiltin(const std::string& name,
                                      const std::string& desc,
                                      const std::string& usage,
                                      BuiltinFn fn) {
    CommandEntry e;
    e.name = name;
    e.desc = desc;
    e.usage = usage;
    e.kind = CommandKind::kBuiltin;
    e.fn = std::move(fn);
    table_[name] = std::move(e);
}

void ShellDispatcher::RegisterExternal(const std::string& name,
                                       const std::string& desc,
                                       const std::string& usage,
                                       bool streaming,
                                       napi_threadsafe_function tsfn) {
    // 覆盖: 先释放旧 external tsfn (若有)
    auto it = table_.find(name);
    if (it != table_.end() &&
        it->second.kind == CommandKind::kExternal &&
        it->second.tsfn) {
        napi_release_threadsafe_function(it->second.tsfn, napi_tsfn_release);
    }
    CommandEntry e;
    e.name = name;
    e.desc = desc;
    e.usage = usage;
    e.kind = CommandKind::kExternal;
    e.streaming = streaming;
    e.tsfn = tsfn;
    table_[name] = std::move(e);
}

bool ShellDispatcher::UnregisterExternal(const std::string& name) {
    auto it = table_.find(name);
    if (it == table_.end()) return false;
    if (it->second.kind != CommandKind::kExternal) return false;
    if (it->second.tsfn) {
        napi_release_threadsafe_function(it->second.tsfn, napi_tsfn_release);
    }
    table_.erase(it);
    return true;
}

const CommandEntry* ShellDispatcher::Find(const std::string& name) const {
    auto it = table_.find(name);
    if (it == table_.end()) return nullptr;
    return &it->second;
}

std::vector<const CommandEntry*> ShellDispatcher::All() const {
    std::vector<const CommandEntry*> out;
    out.reserve(table_.size());
    for (auto& kv : table_) out.push_back(&kv.second);
    std::sort(out.begin(), out.end(),
              [](const CommandEntry* a, const CommandEntry* b) {
                  return a->name < b->name;
              });
    return out;
}

void ShellDispatcher::ReleaseAllExternal() {
    for (auto& kv : table_) {
        if (kv.second.kind == CommandKind::kExternal && kv.second.tsfn) {
            napi_release_threadsafe_function(kv.second.tsfn, napi_tsfn_release);
            kv.second.tsfn = nullptr;
        }
    }
}

} // namespace shell