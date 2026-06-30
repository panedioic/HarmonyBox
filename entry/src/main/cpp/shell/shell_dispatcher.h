#ifndef HBOX_SHELL_DISPATCHER_H
#define HBOX_SHELL_DISPATCHER_H

#include <functional>
#include <string>
#include <unordered_map>
#include <vector>

namespace shell {

class ShellEngine;

using BuiltinFn = std::function<int(ShellEngine& engine,
                                     const std::vector<std::string>& args)>;

struct CommandEntry {
    std::string name;
    std::string desc;
    std::string usage;
    BuiltinFn fn;
};

class ShellDispatcher {
public:
    void RegisterBuiltin(const std::string& name,
                         const std::string& desc,
                         const std::string& usage,
                         BuiltinFn fn);
    const CommandEntry* Find(const std::string& name) const;
    std::vector<const CommandEntry*> All() const;

private:
    std::unordered_map<std::string, CommandEntry> table_;
};

} // namespace shell

#endif