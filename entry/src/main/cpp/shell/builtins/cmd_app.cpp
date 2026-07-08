#include "builtins.h"
#include "../shell_engine.h"
#include "../shell_env.h"
#include "../shell_path.h"

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace shell {

namespace {

// 读整个文件, 上限 1MB (app.json 不该大)
bool ReadWholeFile(const std::string& path, std::string* out, std::string* err) {
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) { *err = strerror(errno); return false; }
    constexpr size_t kMax = 1 * 1024 * 1024;
    char buf[4096];
    out->clear();
    while (out->size() < kMax) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n == 0) break;
        if (n < 0) {
            if (errno == EINTR) continue;
            *err = strerror(errno);
            close(fd);
            return false;
        }
        out->append(buf, buf + n);
    }
    close(fd);
    return true;
}

// 骨架式 name 查找: 允许 "name":"xxx" 和 "name" : "xxx"
// (真实解析等实现容器启动时再上正规 JSON parser)
bool ContainsAppEntry(const std::string& content, const std::string& name) {
    // 拼三种可能的写法, 只要匹配一种即算存在
    std::string variants[] = {
        "\"name\":\"" + name + "\"",
        "\"name\": \"" + name + "\"",
        "\"name\" : \"" + name + "\"",
    };
    for (const auto& v : variants) {
        if (content.find(v) != std::string::npos) return true;
    }
    return false;
}

} // anonymous namespace

int CmdAppLaunch(ShellEngine& e, const std::vector<std::string>& args) {
    if (args.empty()) {
        e.WriteErr("app.launch: usage: app.launch <name>");
        return 2;
    }
    const std::string& name = args[0];

    // 1. 定位 app.json
    std::string apps_json = e.Env().Get("HBOX_APPS_JSON");
    if (apps_json.empty()) {
        std::string files_dir = e.Env().Get("FILES_DIR");
        if (files_dir.empty()) {
            e.WriteErr("app.launch: neither HBOX_APPS_JSON nor FILES_DIR is set");
            return 1;
        }
        apps_json = files_dir + "/apps.json";
    }

    e.Writeln("[1/6] reading \x1b[36m" + apps_json + "\x1b[0m");
    struct stat st;
    if (stat(apps_json.c_str(), &st) != 0) {
        e.WriteErr(std::string("  app.json not found: ") + strerror(errno));
        e.Writeln("\x1b[90m  hint: create ${FILES_DIR}/apps.json or set HBOX_APPS_JSON\x1b[0m");
        return 1;
    }
    std::string content;
    std::string err;
    if (!ReadWholeFile(apps_json, &content, &err)) {
        e.WriteErr("  read failed: " + err);
        return 1;
    }
    e.Writeln("  \x1b[90msize " + std::to_string(content.size()) + " bytes\x1b[0m");

    // 2. 查找 name
    e.Writeln("[2/6] looking up app '\x1b[36m" + name + "\x1b[0m'");
    if (!ContainsAppEntry(content, name)) {
        e.WriteErr("  no such app: " + name);
        e.Writeln("\x1b[90m  hint: expected an entry with \"name\":\"" + name + "\"\x1b[0m");
        return 1;
    }
    e.Writeln("  \x1b[32mfound\x1b[0m");

    // 3~6. TODO
    e.Writeln("[3/6] parsing entry fields");
    e.Writeln("  \x1b[90mtodo: extract container, appDir, exe, args, env\x1b[0m");

    e.Writeln("[4/6] resolving container runtime");
    e.Writeln("  \x1b[90mtodo: dispatch to wine / native / other\x1b[0m");

    e.Writeln("[5/6] preparing launch context");
    e.Writeln("  \x1b[90mtodo: expand ${VAR} in paths, merge env, build argv\x1b[0m");

    e.Writeln("[6/6] launching");
    e.Writeln("  \x1b[90mtodo: spawn via procmgr, register in AppRegistry\x1b[0m");

    e.Writeln("");
    e.Writeln("\x1b[33m(stub: no actual launch performed)\x1b[0m");
    return 0;
}

} // namespace shell