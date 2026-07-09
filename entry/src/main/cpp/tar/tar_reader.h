#ifndef HBOX_TAR_READER_H
#define HBOX_TAR_READER_H

#include <string>

namespace tar {

struct ExtractResult {
    bool ok = false;
    int extracted = 0;
    int skipped = 0;
    std::string error;
};

// 解压 archive 到 dest_dir。dest_dir 必须已存在。
// 会拒绝 ../ 越出 dest_dir 的路径。
ExtractResult Extract(const std::string& archive, const std::string& dest_dir);

}  // namespace tar

#endif