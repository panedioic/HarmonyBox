#ifndef HBOX_SHELL_TOKENIZER_H
#define HBOX_SHELL_TOKENIZER_H

#include <string>
#include <vector>

namespace shell {

struct TokenizeResult {
    std::vector<std::string> tokens;
    bool ok = true;
    std::string error;
};

// 简易分词: 空白分隔, 支持单/双引号, 反斜杠转义
// 不支持: 变量展开 / 通配符 / 管道重定向 (留给后续阶段)
TokenizeResult Tokenize(const std::string& line);

} // namespace shell

#endif