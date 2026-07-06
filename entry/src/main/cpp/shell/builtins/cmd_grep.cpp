#include "builtins.h"
#include "../shell_engine.h"
#include "../shell_path.h"

#include <algorithm>
#include <cstring>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

namespace shell {

namespace {

std::string ToLower(std::string s) {
    for (char& c : s) if (c >= 'A' && c <= 'Z') c += 32;
    return s;
}

bool Match(const std::string& line, const std::string& pat, bool ci) {
    if (!ci) return line.find(pat) != std::string::npos;
    return ToLower(line).find(ToLower(pat)) != std::string::npos;
}

int GrepOne(ShellEngine& e, const std::string& pat, const std::string& path,
            bool ignore_case, bool invert, bool show_lineno, bool show_count,
            bool print_hdr) {
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) {
        e.WriteErr(std::string("grep: ") + path + ": " + strerror(errno));
        return 1;
    }
    if (print_hdr && !show_count) {
        // 不打头, 每行前缀 path:
    }

    std::string line;
    char buf[4096];
    int lineno = 0;
    int match_count = 0;
    while (true) {
        ssize_t got = read(fd, buf, sizeof(buf));
        if (got == 0) break;
        if (got < 0) { if (errno == EINTR) continue; break; }
        for (ssize_t i = 0; i < got; ++i) {
            char c = buf[i];
            if (c == '\n') {
                lineno++;
                bool hit = Match(line, pat, ignore_case);
                if (invert) hit = !hit;
                if (hit) {
                    match_count++;
                    if (!show_count) {
                        std::string out;
                        if (print_hdr)     out += "\x1b[35m" + path + "\x1b[0m:";
                        if (show_lineno)   out += "\x1b[32m" + std::to_string(lineno) + "\x1b[0m:";
                        // 高亮匹配子串 (非 invert / non-ci 才高亮, 简单实现)
                        if (!invert) {
                            std::string hl = line;
                            if (!ignore_case) {
                                size_t p = 0;
                                std::string out_line;
                                while (p < hl.size()) {
                                    size_t f = hl.find(pat, p);
                                    if (f == std::string::npos) {
                                        out_line += hl.substr(p);
                                        break;
                                    }
                                    out_line += hl.substr(p, f - p);
                                    out_line += "\x1b[1;31m" + pat + "\x1b[0m";
                                    p = f + pat.size();
                                }
                                out += out_line;
                            } else {
                                out += hl;
                            }
                        } else {
                            out += line;
                        }
                        out += "\r\n";
                        e.Write(out);
                    }
                }
                line.clear();
            } else if (c != '\r') {
                line.push_back(c);
            }
        }
    }
    // 末尾无换行的最后一行
    if (!line.empty()) {
        lineno++;
        bool hit = Match(line, pat, ignore_case);
        if (invert) hit = !hit;
        if (hit) {
            match_count++;
            if (!show_count) {
                std::string out;
                if (print_hdr)   out += "\x1b[35m" + path + "\x1b[0m:";
                if (show_lineno) out += "\x1b[32m" + std::to_string(lineno) + "\x1b[0m:";
                out += line + "\r\n";
                e.Write(out);
            }
        }
    }
    close(fd);

    if (show_count) {
        std::string out;
        if (print_hdr) out += path + ":";
        out += std::to_string(match_count);
        e.Writeln(out);
    }
    return match_count > 0 ? 0 : 1;
}

} // anonymous namespace

int CmdGrep(ShellEngine& e, const std::vector<std::string>& args) {
    bool ignore_case = false;
    bool invert = false;
    bool show_lineno = false;
    bool show_count = false;
    std::string pattern;
    std::vector<std::string> files;

    for (size_t i = 0; i < args.size(); ++i) {
        const std::string& a = args[i];
        if (a.size() >= 2 && a[0] == '-' && a[1] != '-') {
            for (size_t k = 1; k < a.size(); ++k) {
                switch (a[k]) {
                    case 'i': ignore_case = true; break;
                    case 'v': invert = true; break;
                    case 'n': show_lineno = true; break;
                    case 'c': show_count = true; break;
                    default:
                        e.WriteErr(std::string("grep: unknown option -") + a[k]);
                        return 2;
                }
            }
        } else if (pattern.empty()) {
            pattern = a;
        } else {
            files.push_back(a);
        }
    }
    if (pattern.empty() || files.empty()) {
        e.WriteErr("grep: usage: grep [-i -v -n -c] <pattern> <file...>");
        return 2;
    }

    int any_match = 1;
    bool print_hdr = files.size() > 1;
    for (const auto& f : files) {
        std::string p = ResolvePath(e.Cwd(), e.Home(), f);
        int r = GrepOne(e, pattern, p, ignore_case, invert, show_lineno,
                        show_count, print_hdr);
        if (r == 0) any_match = 0;
    }
    return any_match;
}

} // namespace shell