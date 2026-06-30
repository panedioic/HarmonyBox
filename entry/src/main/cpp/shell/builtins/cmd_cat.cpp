#include "builtins.h"
#include "../shell_engine.h"
#include "../shell_path.h"

#include <cstring>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace shell {

namespace {

// 把 LF 转 CRLF, 二进制裸字节也直通; 超大文件分段读
int CatOne(ShellEngine& e, const std::string& path) {
    struct stat st;
    if (stat(path.c_str(), &st) != 0) {
        e.WriteErr(std::string("cat: ") + path + ": " + strerror(errno));
        return 1;
    }
    if (S_ISDIR(st.st_mode)) {
        e.WriteErr("cat: " + path + ": is a directory");
        return 1;
    }
    // /proc 下 size=0 但有内容, 不能用 size 拦; 用读到的累计字节限上限
    constexpr size_t kMax = 8 * 1024 * 1024;  // 8MB 硬上限
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) {
        e.WriteErr(std::string("cat: ") + path + ": " + strerror(errno));
        return 1;
    }
    char chunk[4096];
    std::string accum;
    accum.reserve(4096);
    size_t total = 0;
    while (true) {
        ssize_t n = read(fd, chunk, sizeof(chunk));
        if (n == 0) break;
        if (n < 0) {
            if (errno == EINTR) continue;
            e.WriteErr(std::string("cat: read: ") + strerror(errno));
            close(fd);
            return 1;
        }
        // CRLF 转换
        accum.clear();
        accum.reserve((size_t)n + 16);
        for (ssize_t i = 0; i < n; ++i) {
            char c = chunk[i];
            if (c == '\n') accum.push_back('\r');
            accum.push_back(c);
        }
        e.Write(accum);
        total += (size_t)n;
        if (total >= kMax) {
            e.WriteErr("cat: file too large, truncated at 8MB");
            break;
        }
    }
    close(fd);
    return 0;
}

} // anonymous namespace

int CmdCat(ShellEngine& e, const std::vector<std::string>& args) {
    if (args.empty()) {
        e.WriteErr("cat: missing file operand");
        return 1;
    }
    int rc = 0;
    for (const auto& a : args) {
        std::string p = ResolvePath(e.Cwd(), e.Home(), a);
        int r = CatOne(e, p);
        if (r != 0) rc = r;
    }
    return rc;
}

} // namespace shell