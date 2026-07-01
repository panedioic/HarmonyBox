#include "builtins.h"
#include "../shell_engine.h"
#include "../shell_env.h"

namespace shell {

namespace {

int PrintOne(ShellEngine& e, const std::string& key) {
    if (!e.Env().Has(key)) {
        e.WriteErr("export: not set: " + key);
        return 1;
    }
    e.Writeln("\x1b[36m" + key + "\x1b[0m=" + e.Env().Get(key));
    return 0;
}

} // anonymous namespace

int CmdExport(ShellEngine& e, const std::vector<std::string>& args) {
    // 无参: 列出所有 shell var (排除 system)
    if (args.empty()) {
        for (const auto& entry : e.Env().All()) {
            if (!entry.persistent && !e.Env().IsReadonly(entry.key)) {
                // 只列 shell 用户设的 (非 readonly, 非仅 system)
            }
            // 简单起见, 全列
            std::string tag = entry.persistent ? " \x1b[33m(saved)\x1b[0m" : "";
            if (entry.readonly) continue;   // readonly 不列
            e.Writeln("\x1b[36m" + entry.key + "\x1b[0m=" + entry.val + tag);
        }
        return 0;
    }

    bool persistent = false;
    size_t i = 0;
    if (args[0] == "--save" || args[0] == "-p") {
        persistent = true;
        i = 1;
    }
    if (i >= args.size()) {
        e.WriteErr("export: missing KEY=VAL");
        return 2;
    }

    int rc = 0;
    for (; i < args.size(); ++i) {
        const std::string& a = args[i];
        size_t eq = a.find('=');
        if (eq == std::string::npos) {
            // 仅打印或标记. 简单起见: 打印
            if (PrintOne(e, a) != 0) rc = 1;
            continue;
        }
        std::string key = a.substr(0, eq);
        std::string val = a.substr(eq + 1);

        int r = e.Env().Set(key, val, persistent);
        if (r == 1) {
            e.WriteErr("export: readonly: " + key);
            rc = 1;
        } else if (r == 2) {
            e.WriteErr("export: persist save failed for " + key);
            rc = 1;
        }
    }
    return rc;
}

} // namespace shell