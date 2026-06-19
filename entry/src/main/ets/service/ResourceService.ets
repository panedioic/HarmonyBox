import wl from 'libentry.so';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { InstallService } from './InstallService';

export interface ResourceProbe {
  installed: boolean;
  path: string;
}

export class ResourceService {
  // 沙箱内安装目录: ${filesDir}/${name}
  static getDir(ctx: common.Context, name: string): string {
    return `${ctx.filesDir}/${name}`;
  }

  static probe(ctx: common.Context, name: string): ResourceProbe {
    const dir: string = ResourceService.getDir(ctx, name);
    let installed: boolean = false;
    try { installed = fs.accessSync(dir); } catch (e) { /* ignore */ }
    return { installed, path: dir } as ResourceProbe;
  }

  // 选一个目录,递归复制到沙箱 ${filesDir}/${name}
  static async pickAndInstall(ctx: common.Context, name: string): Promise<string> {
    const uri: string | null = await InstallService.pickFolder();
    if (!uri) return '已取消';
    const srcPath: string = InstallService.uriToPath(uri);
    if (!srcPath) return '路径解析失败';

    const dst: string = ResourceService.getDir(ctx, name);
    try {
      if (fs.accessSync(dst)) fs.rmdirSync(dst);
    } catch (e) { /* ignore */ }

    try {
      InstallService.copyDirRec(srcPath, dst);
    } catch (e) {
      return `复制失败: ${(e as Error).message}`;
    }

    // 若包含 bin 目录,赋可执行权限(weston 需要,xkb 通常不需要,失败忽略)
    try { wl.chmodDirFiles(`${dst}/bin`); } catch (e) { /* ignore */ }
    return '';
  }

  static uninstall(ctx: common.Context, name: string): void {
    const dir: string = ResourceService.getDir(ctx, name);
    try { if (fs.accessSync(dir)) fs.rmdirSync(dir); } catch (e) { /* ignore */ }
  }
}