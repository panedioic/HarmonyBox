#include "shell_tokenizer.h"

namespace shell {

TokenizeResult Tokenize(const std::string& line) {
    TokenizeResult r;
    std::string cur;
    bool in_token = false;
    char quote = 0;  // 0 / '\'' / '"'

    auto push = [&]() {
        if (in_token) {
            r.tokens.push_back(std::move(cur));
            cur.clear();
            in_token = false;
        }
    };

    for (size_t i = 0; i < line.size(); ++i) {
        char c = line[i];

        if (quote) {
            // 引号内
            if (c == '\\' && quote == '"' && i + 1 < line.size()) {
                char n = line[i + 1];
                // 双引号下仅 \" \\ \n 这几个转义有意义, 其它原样
                if (n == '"' || n == '\\' || n == '$' || n == '`') {
                    cur.push_back(n);
                    ++i;
                    continue;
                }
                cur.push_back(c);
                continue;
            }
            if (c == quote) {
                quote = 0;
                in_token = true;  // 空引号也算 token
                continue;
            }
            cur.push_back(c);
            in_token = true;
            continue;
        }

        // 非引号内
        if (c == '\\') {
            if (i + 1 < line.size()) {
                cur.push_back(line[i + 1]);
                ++i;
                in_token = true;
            }
            continue;
        }
        if (c == '\'' || c == '"') {
            quote = c;
            in_token = true;
            continue;
        }
        if (c == ' ' || c == '\t') {
            push();
            continue;
        }
        cur.push_back(c);
        in_token = true;
    }

    if (quote) {
        r.ok = false;
        r.error = "unclosed quote";
        return r;
    }
    push();
    return r;
}

} // namespace shell