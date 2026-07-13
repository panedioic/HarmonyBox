import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { fileUri } from '@kit.CoreFileKit';
import { resourceManager } from '@kit.LocalizationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import wl from 'libentry.so';

const TAG = 'HBox_UI_Svc_Package';

interface FsReadOpts {
  offset?: number;
  length?: number;
}
interface FsWriteOpts {
  offset?: number;
  length?: number;
  encoding?: string;
}

export interface PackageResult {
  ok: boolean;
  error: string;
}

export class PackageService {

  // ==============================================================
  //  内部: 通用 runCommand + await exit
  // ==============================================================
  private static runTarCommand(
    argv: string[],
    logPrefix: string
  ): Promise<PackageResult> {
    return new Promise<PackageResult>((resolve): void => {
      let settled: boolean = false;
      const startTs: number = Date.now();

      const finish = (ok: boolean, msg: string): void => {
        if (settled) return;
        settled = true;
        const cost: number = (Date.now() - startTs) / 1000;
        hilog.info(0x0000, TAG,
          `[${logPrefix}] done ok=${ok} cost=${cost.toFixed(1)}s msg=${msg}`);
        resolve({ ok: ok, error: ok ? '' : msg });
      };

      const cb = (event: string, data: string): void => {
        if (event === 'out') {
          hilog.info(0x0000, TAG, `[${logPrefix}] tar: ${data}`);
        } else if (event === 'exit') {
          const code: number = parseInt(data, 10);
          if (code === 0) finish(true, 'exit=0');
          else finish(false, `tar exit=${code}`);
        }
      };

      hilog.info(0x0000, TAG, `[${logPrefix}] argv=${argv.join(' ')}`);

      let pid: number = 0;
      try {
        pid = wl.runCommand('tar', argv, [], '', cb);
      } catch (e) {
        finish(false, `spawn exception: ${(e as Error).message}`);
        return;
      }
      if (pid <= 0) {
        finish(false, `spawn failed pid=${pid}`);
        return;
      }
      hilog.info(0x0000, TAG, `[${logPrefix}] pid=${pid}`);
    });
  }

  // ==============================================================
  //  导入: tar URI → 目标目录
  // ==============================================================
  static async importFromTar(
    _ctx: common.Context,
    tarUri: string,
    destDir: string
  ): Promise<PackageResult> {
    const tarPath: string = new fileUri.FileUri(tarUri).path;

    try {
      if (!fs.accessSync(destDir)) fs.mkdirSync(destDir, true);
    } catch (e) {
      return { ok: false, error: `创建目标目录失败: ${(e as Error).message}` };
    }

    hilog.info(0x0000, TAG, `[importTar] ${tarPath} -> ${destDir}`);

    const argv: string[] = ['tar', 'xf', tarPath, '-C', destDir];
    return PackageService.runTarCommand(argv, 'tar');
  }

  // ==============================================================
  //  导入: rawfile → 目标目录 (内置资源)
  // ==============================================================
  static async importFromRawfile(
    ctx: common.Context,
    rawfileName: string,
    destDir: string
  ): Promise<PackageResult> {
    try {
      if (!fs.accessSync(destDir)) fs.mkdirSync(destDir, true);
    } catch (e) {
      return { ok: false, error: `创建目标目录失败: ${(e as Error).message}` };
    }

    // rawfile 存在 HAP zip 内, 先拷贝到 cacheDir 临时文件
    const tmpPath: string = `${ctx.cacheDir}/pkg-${Date.now()}.tar.zst`;
    const copyOk: boolean = PackageService.copyRawfileToTemp(ctx, rawfileName, tmpPath);
    if (!copyOk) {
      return { ok: false, error: `读取内置资源失败: ${rawfileName}` };
    }

    hilog.info(0x0000, TAG, `[importRawfile] ${rawfileName} -> ${destDir}`);

    const argv: string[] = ['tar', 'xf', tmpPath, '-C', destDir];
    const r: PackageResult = await PackageService.runTarCommand(argv, 'tar');

    try { fs.unlinkSync(tmpPath); } catch (_e) { /* ignore */ }
    return r;
  }

  // ==============================================================
  //  导入: 文件夹 URI → 目标目录 (同步复制)
  // ==============================================================
  static importFromFolder(srcFolderUri: string, destDir: string): PackageResult {
    try {
      const srcPath: string = new fileUri.FileUri(srcFolderUri).path;
      if (!srcPath) return { ok: false, error: '无法解析文件夹 URI' };

      PackageService.copyDirRec(srcPath, destDir);
      return { ok: true, error: '' };
    } catch (e) {
      return { ok: false, error: `复制文件夹失败: ${(e as Error).message}` };
    }
  }

  // ==============================================================
  //  导出: 源目录 → tar URI (zstd 压缩)
  // ==============================================================
  static async exportToTar(
    _ctx: common.Context,
    srcDir: string,
    saveUri: string,
    excludeDirs: string[] = []
  ): Promise<PackageResult> {
    const tarPath: string = new fileUri.FileUri(saveUri).path;

    let entries: string[] = [];
    try {
      entries = fs.listFileSync(srcDir);
    } catch (e) {
      return { ok: false, error: `无法读取源目录: ${(e as Error).message}` };
    }

    // 排除指定目录
    if (excludeDirs.length > 0) {
      entries = entries.filter((e): boolean => excludeDirs.indexOf(e) < 0);
    }
    if (entries.length === 0) {
      return { ok: false, error: '源目录为空' };
    }

    const argv: string[] = ['tar', '--zstd', '-cf', tarPath, '-C', srcDir];
    for (const e of entries) argv.push(e);

    hilog.info(0x0000, TAG,
      `[exportTar] pack ${entries.length} entries -> ${tarPath} (zstd)`);

    return PackageService.runTarCommand(argv, 'export');
  }

  // ==============================================================
  //  导出: 源目录 → 文件夹 URI (同步复制)
  // ==============================================================
  static exportToFolder(srcDir: string, destFolderUri: string): PackageResult {
    try {
      const destPath: string = new fileUri.FileUri(destFolderUri).path;
      if (!destPath) return { ok: false, error: '无法解析目标文件夹 URI' };

      PackageService.copyDirRec(srcDir, destPath);
      return { ok: true, error: '' };
    } catch (e) {
      return { ok: false, error: `复制文件夹失败: ${(e as Error).message}` };
    }
  }

  // ==============================================================
  //  内部: rawfile → 临时文件
  // ==============================================================
  private static copyRawfileToTemp(
    ctx: common.Context,
    rawfileName: string,
    tmpPath: string
  ): boolean {
    let rawfd: resourceManager.RawFileDescriptor | null = null;
    let dst: fs.File | null = null;
    try {
      rawfd = ctx.resourceManager.getRawFdSync(rawfileName);
      if (!rawfd || rawfd.length <= 0) {
        hilog.error(0x0000, TAG, `[rawfile] length=0: ${rawfileName}`);
        return false;
      }
      dst = fs.openSync(tmpPath,
        fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);

      const bufSize: number = 256 * 1024;
      const buf: ArrayBuffer = new ArrayBuffer(bufSize);
      let readPos: number = rawfd.offset;
      let remaining: number = rawfd.length;

      while (remaining > 0) {
        const toRead: number = remaining < bufSize ? remaining : bufSize;
        const readOpts: FsReadOpts = { offset: readPos, length: toRead };
        const n: number = fs.readSync(rawfd.fd, buf, readOpts);
        if (n <= 0) break;
        const writeOpts: FsWriteOpts = { length: n };
        fs.writeSync(dst.fd, buf, writeOpts);
        readPos += n;
        remaining -= n;
      }
      return true;
    } catch (e) {
      hilog.error(0x0000, TAG,
        `[rawfile] copy err: ${(e as Error).message}`);
      try { fs.unlinkSync(tmpPath); } catch (_e) { /* ignore */ }
      return false;
    } finally {
      if (dst) { try { fs.closeSync(dst); } catch (_e) { /* ignore */ } }
      if (rawfd) {
        try { ctx.resourceManager.closeRawFdSync(rawfileName); }
        catch (_e) { /* ignore */ }
      }
    }
  }

  // ==============================================================
  //  内部: 递归复制目录
  // ==============================================================
  private static copyDirRec(src: string, dst: string): void {
    try {
      if (!fs.accessSync(dst)) {
        fs.mkdirSync(dst, true);
      }
      const entries: string[] = fs.listFileSync(src);
      for (const name of entries) {
        const srcPath: string = `${src}/${name}`;
        const dstPath: string = `${dst}/${name}`;
        const stat = fs.statSync(srcPath);
        if (stat.isDirectory()) {
          PackageService.copyDirRec(srcPath, dstPath);
        } else {
          PackageService.copyFile(srcPath, dstPath);
        }
      }
    } catch (error) {
      // TODO: Implement error handling.
    }
  }

  private static copyFile(src: string, dst: string): void {
    try {
      const srcFile: fs.File = fs.openSync(src, fs.OpenMode.READ_ONLY);
      const dstFile: fs.File = fs.openSync(dst,
        fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const bufSize: number = 128 * 1024;
      const buf: ArrayBuffer = new ArrayBuffer(bufSize);
      while (true) {
        const n: number = fs.readSync(srcFile.fd, buf);
        if (n <= 0) break;
        const opts: FsWriteOpts = { length: n };
        fs.writeSync(dstFile.fd, buf, opts);
      }
      fs.closeSync(srcFile);
      fs.closeSync(dstFile);
    } catch (error) {
      // TODO: Implement error handling.
    }
  }
}