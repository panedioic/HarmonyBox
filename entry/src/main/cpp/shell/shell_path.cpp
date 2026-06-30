#include "shell_path.h"

#include <vector>

namespace shell {

std::string NormalizePath(const std::string& abs) {
    std::vector<std::string> parts;
    std::string cur;
    for (size_t i = 0; i <= abs.size(); ++i) {
        char c = (i < abs.size()) ? abs[i] : '/';
        if (c == '/') {
            if (cur.empty()) continue;
            if (cur == ".") { cur.clear(); continue; }
            if (cur == "..") {
                if (!parts.empty()) parts.pop_back();
                cur.clear();
                continue;
            }
            parts.push_back(std::move(cur));
            cur.clear();
        } else {
            cur.push_back(c);
        }
    }
    std::string out = "/";
    for (size_t i = 0; i < parts.size(); ++i) {
        if (i > 0) out += "/";
        out += parts[i];
    }
    return out;
}

std::string ResolvePath(const std::string& cwd,
                        const std::string& home,
                        const std::string& input) {
    if (input.empty()) return cwd;
    std::string base;
    if (input == "~") return NormalizePath(home);
    if (input.size() >= 2 && input[0] == '~' && input[1] == '/') {
        base = home + "/" + input.substr(2);
    } else if (input[0] == '/') {
        base = input;
    } else {
        base = cwd + "/" + input;
    }
    return NormalizePath(base);
}

std::string DisplayPath(const std::string& abs, const std::string& home) {
    if (home.empty()) return abs;
    if (abs == home) return "~";
    if (abs.size() > home.size() &&
        abs.compare(0, home.size(), home) == 0 &&
        abs[home.size()] == '/') {
        return "~" + abs.substr(home.size());
    }
    return abs;
}

} // namespace shell