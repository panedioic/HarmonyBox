#ifndef HBOX_SHELL_PATH_H
#define HBOX_SHELL_PATH_H

#include <string>

namespace shell {

// 把用户输入的路径解析为绝对路径
// - 相对路径以 cwd 为基
// - "~" 或 "~/..." 替换为 home
// - 规范化 . / .. / 重复斜杠
std::string ResolvePath(const std::string& cwd,
                        const std::string& home,
                        const std::string& input);

// 规范化绝对路径
std::string NormalizePath(const std::string& abs);

// 显示用: 把 home 前缀替换成 ~
std::string DisplayPath(const std::string& abs, const std::string& home);

} // namespace shell

#endif