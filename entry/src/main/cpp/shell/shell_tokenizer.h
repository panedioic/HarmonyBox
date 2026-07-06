#ifndef HBOX_SHELL_TOKENIZER_H
#define HBOX_SHELL_TOKENIZER_H

#include <functional>
#include <string>
#include <vector>

namespace shell {

using EnvLookupFn = std::function<std::string(const std::string&)>;

struct TokenizeResult {
    std::vector<std::string> tokens;
    bool ok = true;
    std::string error;
};

// lookup 为空时不做变量展开.
// 支持 $VAR, ${VAR}. 单引号内不展开, 双引号内展开.
TokenizeResult Tokenize(const std::string& line, EnvLookupFn lookup = nullptr);

} // namespace shell

#endif