#ifndef HBOX_TAR_READER_H
#define HBOX_TAR_READER_H

#include <string>
#include <cstdint>

namespace tar {

struct ExtractResult {
    bool ok = false;
    int extracted = 0;
    int skipped = 0;
    std::string error;
};

/** 从磁盘路径读 tar 解压 */
ExtractResult Extract(const std::string& archive, const std::string& dest_dir);

/** 从已有 fd 解压。length < 0 表示读到 EOF; 否则只读 length 字节。
 *  offset 是起始位置。fd 由调用者管理生命周期。*/
ExtractResult ExtractFromFd(int fd, int64_t offset, int64_t length,
                            const std::string& dest_dir);

}  // namespace tar

#endif