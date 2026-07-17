import { fileIo as fs } from '@kit.CoreFileKit';
import { picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'HBox_UI_Svc_Lib';

export interface LibFile {
  name: string;
  size: number;       // bytes
  path: string;       // 绝对路径
}

const LIB_DIR_NAME: string = 'x64libs';

export class LibStore {
  static getDir(ctx: common.Context): string {
    const dir: string = `${ctx.filesDir}/${LIB_DIR_NAME}`;
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (e) { /* ignore */ }
    return dir;
  }

  static list(ctx: common.Context): LibFile[] {
    const dir: string = LibStore.getDir(ctx);
    const result: LibFile[] = [];
    try {
      const entries: string[] = fs.listFileSync(dir);
      for (const name of entries) {
        const path: string = `${dir}/${name}`;
        try {
          const stat = fs.statSync(path);
          if (!stat.isDirectory()) {
            result.push({ name, size: stat.size, path } as LibFile);
          }
        } catch (e) { /* ignore */ }
      }
    } catch (e) {
      hilog.error(0x0000, TAG, `LibStore.list failed: ${JSON.stringify(e)}`);
    }
    result.sort((a: LibFile, b: LibFile): number => a.name.localeCompare(b.name));
    return result;
  }

  static async pickAndAdd(ctx: common.Context): Promise<number> {
    try {
      const p = new picker.DocumentViewPicker();
      const opt = new picker.DocumentSelectOptions();
      opt.maxSelectNumber = 50;
      const uris: string[] = await p.select(opt);
      if (!uris || uris.length === 0) return 0;

      const dir: string = LibStore.getDir(ctx);
      let added: number = 0;
      for (const uri of uris) {
        try {
          const segs: string[] = uri.split('/').filter((s: string) => s.length > 0);
          const fname: string = segs[segs.length - 1];
          const dest: string = `${dir}/${fname}`;
          // 通过 fileIo 打开 URI 复制
          const srcFile = fs.openSync(uri, fs.OpenMode.READ_ONLY);
          try {
            const dstFile = fs.openSync(
              dest,
              fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC
            );
            try {
              fs.copyFileSync(srcFile.fd, dstFile.fd);
              added++;
            } finally {
              fs.closeSync(dstFile.fd);
            }
          } finally {
            fs.closeSync(srcFile.fd);
          }
        } catch (e) {
          hilog.error(0x0000, TAG, `copy lib failed: ${JSON.stringify(e)}`);
        }
      }
      return added;
    } catch (e) {
      hilog.error(0x0000, TAG, `pickAndAdd failed: ${JSON.stringify(e)}`);
      return 0;
    }
  }

  static remove(ctx: common.Context, name: string): boolean {
    const path: string = `${LibStore.getDir(ctx)}/${name}`;
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
        return true;
      }
    } catch (e) {
      hilog.error(0x0000, TAG, `LibStore.remove failed: ${JSON.stringify(e)}`);
    }
    return false;
  }

  static clear(ctx: common.Context): number {
    const list = LibStore.list(ctx);
    let n = 0;
    for (const f of list) {
      if (LibStore.remove(ctx, f.name)) n++;
    }
    return n;
  }

  static formatSize(bytes: number): string {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    if (bytes < 1024 * 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
    return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
  }
}