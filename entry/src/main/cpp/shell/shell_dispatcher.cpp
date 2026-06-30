#include "shell_dispatcher.h"
#include <algorithm>

namespace shell {

void ShellDispatcher::RegisterBuiltin(const std::string& name,
                                      const std::string& desc,
                                      const std::string& usage,
                                      BuiltinFn fn) {
    CommandEntry e;
    e.name = name;
    e.desc = desc;
    e.usage = usage;
    e.fn = std::move(fn);
    table_[name] = std::move(e);
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
    // 名字升序
    std::sort(out.begin(), out.end(),
              [](const CommandEntry* a, const CommandEntry* b) {
                  return a->name < b->name;
              });
    return out;
}

} // namespace shell