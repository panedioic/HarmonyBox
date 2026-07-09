#ifndef HBOX_TAR_WRITER_H
#define HBOX_TAR_WRITER_H

#include <string>
#include <cstdint>

namespace tar {

struct CreateResult {
    bool ok = false;
    int included = 0;
    int skipped = 0;
    std::string error;
};

CreateResult Create(const std::string& archive, const std::string& src_dir);
CreateResult CreateToFd(int fd, const std::string& src_dir);

}  // namespace tar

#endif