#ifndef HBOX_SHELL_DISPATCHER_H
#define HBOX_SHELL_DISPATCHER_H

#include <functional>
#include <string>
#include <unordered_map>
#include <vector>

#include "napi/native_api.h"

namespace shell {

class ShellEngine;

using BuiltinFn = std::function<int(ShellEngine& engine,
                                     const std::vector<std::string>& args)>;

enum class CommandKind {
    kBuiltin,
    kExternal,
};

struct CommandEntry {
    std::string name;
    std::string desc;
    std::string usage;
    CommandKind kind = CommandKind::kBuiltin;

    // builtin
    BuiltinFn fn;

    // external (ArkTS callback)
    napi_threadsafe_function tsfn = nullptr;
    bool streaming = false;
};

class ShellDispatcher {
public:
    ~ShellDispatcher();

    void RegisterBuiltin(const std::string& name,
                         const std::string& desc,
                         const std::string& usage,
                         BuiltinFn fn);

    void RegisterExternal(const std::string& name,
                          const std::string& desc,
                          const std::string& usage,
                          bool streaming,
                          napi_threadsafe_function tsfn);

    // 返回 true 表示确实注销了一个 external (会 release tsfn)
    bool UnregisterExternal(const std::string& name);

    const CommandEntry* Find(const std::string& name) const;
    std::vector<const CommandEntry*> All() const;

    // shutdown 时释放所有 external tsfn
    void ReleaseAllExternal();

private:
    std::unordered_map<std::string, CommandEntry> table_;
};

} // namespace shell

#endif