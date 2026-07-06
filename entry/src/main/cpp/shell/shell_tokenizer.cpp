#include "shell_tokenizer.h"

namespace shell {

namespace {

bool IsVarChar(char c, bool first) {
    if (c == '_') return true;
    if (c >= 'A' && c <= 'Z') return true;
    if (c >= 'a' && c <= 'z') return true;
    if (!first && c >= '0' && c <= '9') return true;
    return false;
}

// 从 line[i] 开始尝试解析 $VAR / ${VAR}, 展开到 out
// 返回消耗的字符数 (含 $). 若 lookup 空或无匹配, 原样输出 $
int TryExpandVar(const std::string& line, size_t i, EnvLookupFn lookup,
                 std::string& out) {
    if (i >= line.size() || line[i] != '$') return 0;
    if (i + 1 >= line.size()) {
        out.push_back('$');
        return 1;
    }
    char next = line[i + 1];
    if (next == '{') {
        size_t j = i + 2;
        std::string name;
        while (j < line.size() && line[j] != '}') {
            name.push_back(line[j]);
            j++;
        }
        if (j >= line.size()) {
            // 未闭合, 原样
            out.push_back('$');
            return 1;
        }
        if (lookup) out += lookup(name);
        return (int)(j + 1 - i);
    }
    if (IsVarChar(next, true)) {
        size_t j = i + 1;
        std::string name;
        while (j < line.size() && IsVarChar(line[j], false)) {
            name.push_back(line[j]);
            j++;
        }
        if (lookup) out += lookup(name);
        return (int)(j - i);
    }
    // $ 后不是变量, 原样输出
    out.push_back('$');
    return 1;
}

} // anonymous namespace

TokenizeResult Tokenize(const std::string& line, EnvLookupFn lookup) {
    TokenizeResult r;
    std::string cur;
    bool in_token = false;
    char quote = 0;

    auto push = [&]() {
        if (in_token) {
            r.tokens.push_back(std::move(cur));
            cur.clear();
            in_token = false;
        }
    };

    for (size_t i = 0; i < line.size(); ) {
        char c = line[i];

        if (quote == '\'') {
            // 单引号: 完全原样
            if (c == '\'') { quote = 0; in_token = true; i++; continue; }
            cur.push_back(c);
            in_token = true;
            i++;
            continue;
        }
        if (quote == '"') {
            if (c == '\\' && i + 1 < line.size()) {
                char n = line[i + 1];
                if (n == '"' || n == '\\' || n == '$' || n == '`') {
                    cur.push_back(n);
                    i += 2;
                    continue;
                }
                cur.push_back(c);
                i++;
                continue;
            }
            if (c == '"') { quote = 0; in_token = true; i++; continue; }
            if (c == '$') {
                int adv = TryExpandVar(line, i, lookup, cur);
                if (adv > 0) { i += adv; in_token = true; continue; }
            }
            cur.push_back(c);
            in_token = true;
            i++;
            continue;
        }

        // 无引号
        if (c == '\\' && i + 1 < line.size()) {
            cur.push_back(line[i + 1]);
            in_token = true;
            i += 2;
            continue;
        }
        if (c == '\'' || c == '"') { quote = c; in_token = true; i++; continue; }
        if (c == ' ' || c == '\t') { push(); i++; continue; }
        if (c == '$') {
            int adv = TryExpandVar(line, i, lookup, cur);
            if (adv > 0) { i += adv; in_token = true; continue; }
        }
        cur.push_back(c);
        in_token = true;
        i++;
    }
    if (quote) { r.ok = false; r.error = "unclosed quote"; return r; }
    push();
    return r;
}

} // namespace shell