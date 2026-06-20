#!/usr/bin/env python3
"""
pack_libs.py - 打包指定库及其所有依赖的 .so 文件
用法: python3 pack_libs.py [--arch arm64-v8a] [--output ./output] [--no-tar]
"""

import os
import re
import shutil
import subprocess
import argparse
import tarfile
from pathlib import Path

# ============================================================
# 配置区：按需修改
# ============================================================
LYCIUM_USR = Path("/workspace/tpc_c_cplusplus/lycium/usr")

# 要打包的目标库（只列顶层，依赖会自动追踪）
TARGET_LIBS = [
    "pixman",
    "cairo",
    "libxkbcommon",
    "fontconfig",
    "freetype2",
    "ohos_stubs",
]

# 额外的文件别名：从 key 复制一份命名为 value 列表里的每一项
# 用途：box64 wrapper 通常按 x86_64 glibc 的 soname 匹配（如 libpng16.so.16）
#       但我们交叉编译出来的 SONAME 可能是 libpng16.so，需要补一份
EXTRA_ALIASES = {
    "libpng16.so": ["libpng16.so.16"],
}

# 自动把 NEEDED 里的 key 替换成 value
# 让 cairo 等库的 DT_NEEDED 引用 box64 wrapper 期望的名字
NEEDED_REPLACE = {
    # "libpng16.so": "libpng16.so.16",
}

OHOS_SDK = Path(os.environ.get("OHOS_SDK", "/workspace/ohos-sdk/linux"))
READELF_CANDIDATES = [
    OHOS_SDK / "native/llvm/bin/llvm-readelf",
    Path("/usr/bin/readelf"),
    Path("/usr/bin/llvm-readelf"),
]

# ============================================================

def fix_needed_paths(output_dir: Path, readelf: Path) -> None:
    patchelf = shutil.which("patchelf")
    if not patchelf:
        print("[warn] patchelf 未找到,跳过 DT_NEEDED 路径修正")
        print("       请执行: apt-get install -y patchelf")
        return

    for so_file in sorted(output_dir.glob("*.so*")):
        if not so_file.is_file():
            continue

        try:
            result = subprocess.run(
                [str(readelf), "-d", str(so_file)],
                capture_output=True, text=True, timeout=30
            )
        except subprocess.TimeoutExpired:
            continue

        for line in result.stdout.splitlines():
            m = re.search(r'\(NEEDED\)\s+Shared library:\s+\[(.+?)\]', line)
            if not m:
                continue
            needed = m.group(1)

            # 步骤 1: 绝对路径转 basename
            if needed.startswith("/"):
                basename = os.path.basename(needed)
                print(f"  [fix]  {so_file.name}: {needed}  ->  {basename}")
                subprocess.run(
                    [patchelf, "--replace-needed", needed, basename, str(so_file)],
                    check=True
                )
                needed = basename  # 用替换后的名字继续做下一步

            # 步骤 2: 应用配置的 NEEDED 替换
            if needed in NEEDED_REPLACE:
                replaced = NEEDED_REPLACE[needed]
                print(f"  [rename] {so_file.name}: {needed}  ->  {replaced}")
                subprocess.run(
                    [patchelf, "--replace-needed", needed, replaced, str(so_file)],
                    check=True
                )

def find_readelf() -> Path:
    for p in READELF_CANDIDATES:
        if p.exists():
            return p
    result = shutil.which("llvm-readelf") or shutil.which("readelf")
    if result:
        return Path(result)
    raise RuntimeError("找不到 readelf / llvm-readelf，请安装 binutils 或检查 OHOS_SDK 路径")

def get_needed(so_path: Path, readelf: Path) -> list[str]:
    try:
        result = subprocess.run(
            [str(readelf), "-d", str(so_path)],
            capture_output=True, text=True, timeout=30
        )
    except subprocess.TimeoutExpired:
        print(f"  [warn] readelf 超时: {so_path}")
        return []

    needed = []
    for line in result.stdout.splitlines():
        m = re.search(r'\(NEEDED\)\s+Shared library:\s+\[(.+?)\]', line)
        if m:
            needed.append(m.group(1))
    return needed

def resolve_real_file(path: Path) -> Path:
    visited = set()
    while path.is_symlink():
        if path in visited:
            raise RuntimeError(f"符号链接循环: {path}")
        visited.add(path)
        target = os.readlink(path)
        if not os.path.isabs(target):
            target = path.parent / target
        path = Path(target).resolve()
    return path

def build_so_index(arch: str) -> dict[str, Path]:
    index: dict[str, Path] = {}
    for lib_dir in LYCIUM_USR.iterdir():
        arch_dir = lib_dir / arch
        lib_path = arch_dir / "lib"
        if not lib_path.exists():
            continue
        for f in lib_path.rglob("*.so*"):
            real = resolve_real_file(f) if f.is_symlink() else f
            if not real.is_file():
                continue
            if f.name not in index:
                index[f.name] = real
            if real.name not in index:
                index[real.name] = real
            if str(f) not in index:
                index[str(f)] = real
            if str(real) not in index:
                index[str(real)] = real
    return index

def find_so_for_needed(needed: str, so_index: dict[str, Path]) -> Path | None:
    def _lookup(name: str) -> Path | None:
        if name in so_index:
            return so_index[name]
        for idx_name, path in so_index.items():
            if idx_name.startswith(name):
                return path
        base = name.split(".so")[0] + ".so"
        for idx_name, path in so_index.items():
            if idx_name.startswith(base):
                return path
        return None

    result = _lookup(needed)
    if result:
        return result

    if needed.startswith("/"):
        basename = os.path.basename(needed)
        result = _lookup(basename)
        if result:
            return result

        real = Path(needed)
        if real.exists():
            return resolve_real_file(real) if real.is_symlink() else real
        parent = real.parent
        stem = real.name
        for candidate in parent.glob(f"{stem}*"):
            if candidate.is_file() and not candidate.is_symlink():
                return candidate
            if candidate.is_symlink():
                resolved = resolve_real_file(candidate)
                if resolved.exists():
                    return resolved

    return None

def collect_with_deps(
    start_libs: list[str],
    arch: str,
    readelf: Path,
    so_index: dict[str, Path],
) -> dict[str, Path]:
    SKIP_PREFIXES = (
        "libc.so", "libm.so", "libdl.so", "libpthread.so",
        "librt.so", "libgcc_s.so", "libstdc++.so",
        "ld-", "ld.so", "libgomp.so",
        # OHOS musl 系统库
        "libclang_rt", "libunwind",
        # 注意：libresolv.so 不在 SKIP 列表里，由 ohos_stubs 提供
    )

    collected: dict[str, Path] = {}
    queue: list[Path] = []

    for lib_name in start_libs:
        arch_dir = LYCIUM_USR / lib_name / arch / "lib"
        if not arch_dir.exists():
            print(f"[warn] 找不到库目录: {arch_dir}")
            continue
        for f in arch_dir.rglob("*.so*"):
            real = resolve_real_file(f) if f.is_symlink() else f
            if real.is_file() and real not in queue:
                queue.append(real)
                collected[real.name] = real

    visited_files: set[Path] = set(queue)
    while queue:
        current = queue.pop(0)
        needed_list = get_needed(current, readelf)
        for needed in needed_list:
            if any(needed.startswith(p) for p in SKIP_PREFIXES):
                continue
            real = find_so_for_needed(needed, so_index)
            if real is None:
                print(f"  [warn] 找不到依赖: {needed}  (needed by {current.name})")
                continue
            if real in visited_files:
                continue
            visited_files.add(real)
            queue.append(real)
            collected[real.name] = real
            print(f"  [dep]  {current.name}  ->  {needed}  ({real})")

    return collected

def pack(collected: dict[str, Path], output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)

    for dest_name, real_src in sorted(collected.items()):
        dest = output_dir / dest_name
        print(f"  [copy] {real_src.name}  ->  {dest}")
        shutil.copy2(real_src, dest)

    # 自动版本链：从带版本号文件生成短版本副本
    existing = {f.name for f in output_dir.glob("*.so*")}
    for fname in list(existing):
        parts = fname.split(".so")
        if len(parts) < 2:
            continue
        base = parts[0] + ".so"
        version_str = parts[1]
        if not version_str:
            continue

        version_parts = version_str.lstrip(".").split(".")
        for i in range(len(version_parts)):
            short_ver = ".".join(version_parts[:i])
            candidate = base + ("." + short_ver if short_ver else "")
            if candidate not in existing:
                src = output_dir / fname
                dst = output_dir / candidate
                print(f"  [dup]  {fname}  ->  {candidate}  (真实文件副本)")
                shutil.copy2(src, dst)
                existing.add(candidate)

    # 配置的额外别名（短文件名 -> 长版本名）
    for src_name, alias_list in EXTRA_ALIASES.items():
        src = output_dir / src_name
        if not src.exists():
            print(f"  [warn] 别名源文件不存在: {src_name}, 跳过 {alias_list}")
            continue
        for alias in alias_list:
            dst = output_dir / alias
            if dst.exists():
                continue
            print(f"  [alias] {src_name}  ->  {alias}")
            shutil.copy2(src, dst)

def clean_output_dir(output_dir: Path) -> None:
    """如果输出目录已存在且非空，清空它"""
    if not output_dir.exists():
        return
    has_content = any(output_dir.iterdir())
    if has_content:
        print(f"=== 清空已存在的输出目录: {output_dir} ===")
        shutil.rmtree(output_dir)
    else:
        # 空目录直接删掉，让后面 mkdir 重建
        output_dir.rmdir()

def make_tarball(output_dir: Path, arch: str) -> Path:
    """把输出目录打成 tar.gz，方便传输到 Windows / 部署机"""
    tar_path = output_dir.parent / f"packed_libs_{arch}.tar.gz"
    if tar_path.exists():
        tar_path.unlink()

    print(f"\n=== 打包 tarball ===")
    with tarfile.open(tar_path, "w:gz") as tar:
        # arcname 用 arch 作为顶层目录，解压出来就是 arm64-v8a/...
        tar.add(output_dir, arcname=arch)

    size = tar_path.stat().st_size
    print(f"  生成: {tar_path}")
    print(f"  大小: {size:,} bytes ({size / 1024 / 1024:.2f} MiB)")
    return tar_path

def main():
    parser = argparse.ArgumentParser(description="打包 lycium 库及其依赖的 .so 文件")
    parser.add_argument("--arch", default="arm64-v8a",
                        help="目标架构，默认 arm64-v8a")
    parser.add_argument("--output", default="./packed_libs",
                        help="输出目录，默认 ./packed_libs")
    parser.add_argument("--libs", nargs="*", default=None,
                        help="要打包的库名，默认使用脚本内 TARGET_LIBS")
    parser.add_argument("--no-tar", action="store_true",
                        help="跳过自动 tar.gz 打包")
    args = parser.parse_args()

    arch = args.arch
    output_dir = Path(args.output) / arch
    target_libs = args.libs if args.libs else TARGET_LIBS

    print(f"架构:     {arch}")
    print(f"目标库:   {target_libs}")
    print(f"输出目录: {output_dir}")
    print()

    # 清空输出目录
    clean_output_dir(output_dir)

    readelf = find_readelf()
    print(f"readelf:  {readelf}\n")

    print("=== 建立全局 .so 索引 ===")
    so_index = build_so_index(arch)
    print(f"索引条目: {len(so_index)} 个\n")

    print("=== 追踪依赖 ===")
    collected = collect_with_deps(target_libs, arch, readelf, so_index)
    print(f"\n共收集 {len(collected)} 个 .so 文件\n")

    print("=== 复制文件 ===")
    pack(collected, output_dir)

    print("\n=== 修正 DT_NEEDED 绝对路径 ===")
    fix_needed_paths(output_dir, readelf)

    print(f"\n完成。产物在: {output_dir}")
    print("\n文件清单:")
    for f in sorted(output_dir.glob("*.so*")):
        size = f.stat().st_size
        print(f"  {f.name:<50} {size:>10,} bytes")

    if not args.no_tar:
        make_tarball(output_dir, arch)

if __name__ == "__main__":
    main()