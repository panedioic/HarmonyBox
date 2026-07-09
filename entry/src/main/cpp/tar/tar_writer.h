#ifndef HBOX_TAR_WRITER_H
#define HBOX_TAR_WRITER_H

#include <string>

namespace tar {

struct CreateResult {
    bool ok = false;
    int included = 0;
    int skipped = 0;
    std::string error;
};

// 递归打包 src_dir 里的内容到 archive 文件。
// tar 里的路径不含 src_dir 前缀 (类似 `tar -C src_dir -cf archive .`)。
CreateResult Create(const std::string& archive, const std::string& src_dir);

}  // namespace tar

#endif