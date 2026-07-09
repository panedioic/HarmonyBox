#ifndef HBOX_TAR_FORMAT_H
#define HBOX_TAR_FORMAT_H

#include <cstdint>
#include <cstddef>

namespace tar {

constexpr size_t kBlockSize = 512;

// USTAR type flags
constexpr char kTypeRegular    = '0';
constexpr char kTypeRegularOld = '\0';  // 老 tar 用 NUL
constexpr char kTypeHardlink   = '1';
constexpr char kTypeSymlink    = '2';
constexpr char kTypeCharDev    = '3';
constexpr char kTypeBlockDev   = '4';
constexpr char kTypeDirectory  = '5';
constexpr char kTypeFifo       = '6';
constexpr char kTypeContiguous = '7';
constexpr char kTypeGnuLongLink = 'K';  // GNU: 下个块的 linkname 是长的
constexpr char kTypeGnuLongName = 'L';  // GNU: 下个块的 name 是长的

struct RawHeader {
    char name[100];
    char mode[8];
    char uid[8];
    char gid[8];
    char size[12];
    char mtime[12];
    char chksum[8];
    char typeflag;
    char linkname[100];
    char magic[6];       // "ustar\0" 或 "ustar "
    char version[2];     // "00"
    char uname[32];
    char gname[32];
    char devmajor[8];
    char devminor[8];
    char prefix[155];
    char padding[12];
};
static_assert(sizeof(RawHeader) == kBlockSize, "USTAR header must be 512 bytes");

}  // namespace tar

#endif