#include "builtins.h"
#include "../shell_engine.h"
#include "../shell_path.h"

#include <cstdlib>
#include <cstring>
#include <deque>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

namespace shell {

namespace {

int TailOne(ShellEngine& e, const std::string& path, int n, bool print_hdr) {
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) {
        e.WriteErr(std::string("tail: ") + path + ": " + strerror(errno));
        return 1;
    }
    if (print_hdr) e.Writeln("\x1b[1;35m==> " + path + " <==\x1b[0m");

    // 简单实现: 读全文, 保留最后 n 行. 8MB 上限
    constexpr size_t kMax = 8 * 1024 * 1024;
    std::string all;
    all.reserve(64 * 1024);
    char buf[4096];
    while (all.size() < kMax) {
        ssize_t got = read(fd, buf, sizeof(buf));
        if (got == 0) break;
        if (got < 0) { if (errno == EINTR) continue; break; }
        all.append(buf, buf + got);
    }
    close(fd);

    // 从末尾找 n 个 \n
    std::deque<size_t> nls;
    for (size_t i = 0; i < all.size(); ++i) {
        if (all[i] == '\n') nls.push_back(i);
    }
    size_t start = 0;
    if ((int)nls.size() > n) {
        // 从倒数第 n 个 \n 之后开始
        start = nls[nls.size() - n - 1] + 1;
    }

    // 输出 (LF -> CRLF)
    std::string out;
    out.reserve(all.size() - start + 32);
    for (size_t i = start; i < all.size(); ++i) {
        char c = all[i];
        if (c == '\n') out.push_back('\r');
        out.push_back(c);
    }
    if (!out.empty() && out.back() != '\n') out += "\r\n";
    e.Write(out);
    return 0;
}

} // anonymous namespace

int CmdTail(ShellEngine& e, const std::vector<std::string>& args) {
    int n = 10;
    std::vector<std::string> files;
    for (size_t i = 0; i < args.size(); ++i) {
        const std::string& a = args[i];
        if (a == "-n" && i + 1 < args.size()) {
            n = atoi(args[i + 1].c_str());
            if (n <= 0) n = 10;
            ++i;
        } else if (a.size() > 2 && a[0] == '-' && a[1] == 'n') {
            n = atoi(a.c_str() + 2);
            if (n <= 0) n = 10;
        } else if (a == "-f") {
            e.WriteErr("tail: -f not implemented yet");
            return 2;
        } else {
            files.push_back(a);
        }
    }
    if (files.empty()) {
        e.WriteErr("tail: missing file");
        return 2;
    }
    int rc = 0;
    bool hdr = files.size() > 1;
    for (size_t i = 0; i < files.size(); ++i) {
        if (hdr && i > 0) e.Writeln("");
        std::string p = ResolvePath(e.Cwd(), e.Home(), files[i]);
        if (TailOne(e, p, n, hdr) != 0) rc = 1;
    }
    return rc;
}

} // namespace shell