#include "builtins.h"
#include "../shell_engine.h"
#include "../shell_path.h"

#include <cstdlib>
#include <cstring>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

namespace shell {

namespace {

int HeadOne(ShellEngine& e, const std::string& path, int n, bool print_hdr) {
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) {
        e.WriteErr(std::string("head: ") + path + ": " + strerror(errno));
        return 1;
    }
    if (print_hdr) e.Writeln("\x1b[1;35m==> " + path + " <==\x1b[0m");

    char buf[4096];
    int lines = 0;
    std::string accum;
    while (lines < n) {
        ssize_t got = read(fd, buf, sizeof(buf));
        if (got == 0) break;
        if (got < 0) {
            if (errno == EINTR) continue;
            break;
        }
        for (ssize_t i = 0; i < got && lines < n; ++i) {
            char c = buf[i];
            if (c == '\n') {
                accum.push_back('\r');
                accum.push_back('\n');
                e.Write(accum);
                accum.clear();
                lines++;
            } else {
                accum.push_back(c);
            }
        }
    }
    if (lines < n && !accum.empty()) {
        e.Write(accum);
        e.Write("\r\n");
    }
    close(fd);
    return 0;
}

} // anonymous namespace

int CmdHead(ShellEngine& e, const std::vector<std::string>& args) {
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
        } else {
            files.push_back(a);
        }
    }
    if (files.empty()) {
        e.WriteErr("head: missing file");
        return 2;
    }
    int rc = 0;
    bool hdr = files.size() > 1;
    for (size_t i = 0; i < files.size(); ++i) {
        if (hdr && i > 0) e.Writeln("");
        std::string p = ResolvePath(e.Cwd(), e.Home(), files[i]);
        if (HeadOne(e, p, n, hdr) != 0) rc = 1;
    }
    return rc;
}

} // namespace shell