#include "builtins.h"
#include "../shell_engine.h"
#include "../shell_path.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <errno.h>
#include <sys/stat.h>

namespace shell {

namespace {

std::string ColorEntry(const std::string& name, const struct stat* st) {
    if (!st) return name;
    if (S_ISDIR(st->st_mode))  return "\x1b[1;34m" + name + "\x1b[0m";
    if (S_ISLNK(st->st_mode))  return "\x1b[1;36m" + name + "\x1b[0m";
    if (S_ISSOCK(st->st_mode)) return "\x1b[1;35m" + name + "\x1b[0m";
    if ((st->st_mode & 0111) != 0) return "\x1b[1;32m" + name + "\x1b[0m";
    return name;
}

std::string PermString(mode_t m) {
    std::string s;
    s.reserve(10);
    s += S_ISDIR(m)  ? 'd' :
         S_ISLNK(m)  ? 'l' :
         S_ISSOCK(m) ? 's' :
         S_ISCHR(m)  ? 'c' :
         S_ISBLK(m)  ? 'b' :
         S_ISFIFO(m) ? 'p' : '-';
    s += (m & 0400) ? 'r' : '-';
    s += (m & 0200) ? 'w' : '-';
    s += (m & 0100) ? 'x' : '-';
    s += (m & 0040) ? 'r' : '-';
    s += (m & 0020) ? 'w' : '-';
    s += (m & 0010) ? 'x' : '-';
    s += (m & 0004) ? 'r' : '-';
    s += (m & 0002) ? 'w' : '-';
    s += (m & 0001) ? 'x' : '-';
    return s;
}

void PrintColumns(ShellEngine& e,
                  const std::vector<std::string>& colored_names,
                  const std::vector<int>& raw_lens,
                  int term_cols) {
    if (colored_names.empty()) return;
    int max_w = 0;
    for (int w : raw_lens) if (w > max_w) max_w = w;
    int col_w = max_w + 2;
    int cols = std::max(1, term_cols / col_w);
    int n = (int)colored_names.size();
    int rows = (n + cols - 1) / cols;

    // 按列优先打印
    for (int r = 0; r < rows; ++r) {
        std::string line;
        for (int c = 0; c < cols; ++c) {
            int idx = c * rows + r;
            if (idx >= n) break;
            line += colored_names[idx];
            int pad = col_w - raw_lens[idx];
            if (c < cols - 1 && idx + rows < n && pad > 0) {
                line.append(pad, ' ');
            }
        }
        e.Writeln(line);
    }
}

int LsOne(ShellEngine& e, const std::string& path,
          bool show_all, bool long_fmt) {
    struct stat st;
    if (lstat(path.c_str(), &st) != 0) {
        e.WriteErr(std::string("ls: ") + path + ": " + strerror(errno));
        return 1;
    }

    if (!S_ISDIR(st.st_mode)) {
        std::string name = path;
        size_t slash = path.rfind('/');
        if (slash != std::string::npos) name = path.substr(slash + 1);
        if (long_fmt) {
            char buf[64];
            snprintf(buf, sizeof(buf), "%s %10lld  ",
                     PermString(st.st_mode).c_str(),
                     (long long)st.st_size);
            e.Writeln(std::string(buf) + ColorEntry(name, &st));
        } else {
            e.Writeln(ColorEntry(name, &st));
        }
        return 0;
    }

    DIR* d = opendir(path.c_str());
    if (!d) {
        e.WriteErr(std::string("ls: ") + path + ": " + strerror(errno));
        return 1;
    }

    std::vector<std::string> names;
    struct dirent* de;
    while ((de = readdir(d)) != nullptr) {
        std::string n = de->d_name;
        if (n == "." || n == "..") continue;
        if (!show_all && !n.empty() && n[0] == '.') continue;
        names.push_back(std::move(n));
    }
    closedir(d);

    std::sort(names.begin(), names.end());

    if (long_fmt) {
        for (const auto& n : names) {
            std::string full = path + "/" + n;
            struct stat st2;
            if (lstat(full.c_str(), &st2) == 0) {
                char buf[64];
                snprintf(buf, sizeof(buf), "%s %10lld  ",
                         PermString(st2.st_mode).c_str(),
                         (long long)st2.st_size);
                e.Writeln(std::string(buf) + ColorEntry(n, &st2));
            } else {
                e.Writeln("?         " + n);
            }
        }
    } else {
        std::vector<std::string> colored;
        std::vector<int> raw_lens;
        colored.reserve(names.size());
        raw_lens.reserve(names.size());
        for (const auto& n : names) {
            std::string full = path + "/" + n;
            struct stat st2;
            bool ok = (lstat(full.c_str(), &st2) == 0);
            colored.push_back(ColorEntry(n, ok ? &st2 : nullptr));
            raw_lens.push_back((int)n.size());
        }
        PrintColumns(e, colored, raw_lens, e.Cols());
    }
    return 0;
}

} // anonymous namespace

int CmdLs(ShellEngine& e, const std::vector<std::string>& args) {
    bool show_all = false;
    bool long_fmt = false;
    std::vector<std::string> targets;
    for (const auto& a : args) {
        if (a == "-a" || a == "--all") show_all = true;
        else if (a == "-l") long_fmt = true;
        else if (a == "-la" || a == "-al") { show_all = true; long_fmt = true; }
        else targets.push_back(a);
    }
    if (targets.empty()) {
        return LsOne(e, e.Cwd(), show_all, long_fmt);
    }
    int rc = 0;
    for (size_t i = 0; i < targets.size(); ++i) {
        std::string p = ResolvePath(e.Cwd(), e.Home(), targets[i]);
        if (targets.size() > 1) {
            if (i > 0) e.Writeln("");
            e.Writeln(DisplayPath(p, e.Home()) + ":");
        }
        int r = LsOne(e, p, show_all, long_fmt);
        if (r != 0) rc = r;
    }
    return rc;
}

} // namespace shell