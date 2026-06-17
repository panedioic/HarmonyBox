import wl from 'libentry.so';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { InstallService } from './InstallService';
import { LibStore } from './LibStore';

const WINE_DIR_NAME: string = 'wine';
const PREFIX_DIR_NAME: string = 'wineprefix';
const BOX64_PATH: string = '/data/service/hnp/bin/box64';

export interface WineStatus {
  installed: boolean;
  rootDir: string;
  binPath: string;
  prefixDir: string;
  version: string;
}

export class WineService {
  static getRootDir(ctx: common.Context): string {
    return `${ctx.filesDir}/${WINE_DIR_NAME}`;
  }

  static getBinPath(ctx: common.Context): string {
    return `${WineService.getRootDir(ctx)}/bin/wine`;
  }

  static getPrefixDir(ctx: common.Context): string {
    const dir: string = `${ctx.filesDir}/${PREFIX_DIR_NAME}`;
    try { if (!fs.accessSync(dir)) fs.mkdirSync(dir, true); } catch (e) { /* ignore */ }
    return dir;
  }

  static probe(ctx: common.Context): WineStatus {
    const root: string = WineService.getRootDir(ctx);
    const bin: string = WineService.getBinPath(ctx);
    let installed: boolean = false;
    try { installed = fs.accessSync(bin); } catch (e) { /* ignore */ }
    return {
      installed, rootDir: root, binPath: bin,
      prefixDir: WineService.getPrefixDir(ctx),
      version: installed ? '...' : ''
    } as WineStatus;
  }

  // 选文件夹并安装。要求源目录有 bin/wine
  static async pickAndInstall(ctx: common.Context): Promise<string> {
    const uri: string | null = await InstallService.pickFolder();
    if (!uri) return '已取消';

    const srcPath: string = InstallService.uriToPath(uri);
    if (!srcPath) return '路径解析失败';
    const wineExe: string = `${srcPath}/bin/wine`;
    try {
      if (!fs.accessSync(wineExe)) {
        return '所选目录缺少 bin/wine,请选择 wine 根目录';
      }
    } catch (e) { return '校验源目录失败'; }

    const root: string = WineService.getRootDir(ctx);
    try {
      if (fs.accessSync(root)) fs.rmdirSync(root);
    } catch (e) { /* ignore */ }

    try {
      InstallService.copyDirRec(srcPath, root);
    } catch (e) {
      return `复制失败: ${(e as Error).message}`;
    }

    // chmod 关键目录
    try {
      wl.chmodDirFiles(`${root}/bin`);
      wl.chmodDirFiles(`${root}/lib/wine/x86_64-unix`);
    } catch (e) { /* ignore */ }

    return '';
  }

  static uninstall(ctx: common.Context): void {
    const root: string = WineService.getRootDir(ctx);
    try { if (fs.accessSync(root)) fs.rmdirSync(root); } catch (e) { /* ignore */ }
    const prefix: string = `${ctx.filesDir}/${PREFIX_DIR_NAME}`;
    try { if (fs.accessSync(prefix)) fs.rmdirSync(prefix); } catch (e) { /* ignore */ }
  }

  // 探测版本: box64 wine --version
  static async fetchVersion(ctx: common.Context): Promise<string> {
    const status: WineStatus = WineService.probe(ctx);
    if (!status.installed) return '';
    const libPath: string = (ctx as common.UIAbilityContext).applicationInfo.nativeLibraryPath ?? '';
    const argv: string[] = [BOX64_PATH, status.binPath, '--version'];

    // 完整 env:wine 自己的 lib + 全局 x64libs + WINEPREFIX 这一套
    const ldPaths: string[] = WineService.buildLdPaths(ctx);
    const x64Libs: string = LibStore.getDir(ctx);
    if (x64Libs) ldPaths.push(x64Libs);

    const env: string[] = [
      `BOX64_LD_LIBRARY_PATH=${ldPaths.join(':')}`,
      `BOX64_NOBANNER=1`
    ];
    for (const e of WineService.buildLaunchEnv(ctx)) env.push(e);

    try {
      const r = await wl.execCapture(BOX64_PATH, argv, libPath, env);
      const out: string = r.stdout || '';
      const v: string = WineService.pickVersionLine(out);
      if (v.length > 0) return v;
      if (r.code === 0) return '已安装';
      return `已安装 (exit ${r.code})`;
    } catch (e) {
      return '已安装 (版本读取失败)';
    }
  }

  // 从 stdout 里挑出真正的版本行,过滤 sh/wine/box64 的报错噪音
  private static pickVersionLine(stdout: string): string {
    const lines: string[] = stdout.split('\n');
    for (const raw of lines) {
      const line: string = raw.trim();
      if (line.length === 0) continue;
      // 1. wine 版本行: 形如 "wine-9.0" 或 "wine-9.0 (Staging)"
      if (/^wine[-\s]/i.test(line)) return line;
    }
    // 2. fallback:跳过明显是错误的行,选第一个看起来像版本的
    for (const raw of lines) {
      const line: string = raw.trim();
      if (line.length === 0) continue;
      if (line.startsWith('sh:')) continue;
      if (line.startsWith('wine:')) continue;
      if (line.toLowerCase().includes('error')) continue;
      if (line.toLowerCase().includes('cannot')) continue;
      if (line.toLowerCase().includes('not found')) continue;
      return line;
    }
    return '';
  }

  // 给 wine 应用启动用的 env
  static buildLaunchEnv(ctx: common.Context): string[] {
    const root: string = WineService.getRootDir(ctx);
    return [
      `WINEPREFIX=${WineService.getPrefixDir(ctx)}`,
      `WINEDEBUG=-all`,
      `WINELOADER=${root}/bin/wine`,
      `WINESERVER=${root}/bin/wineserver`
    ];
  }

  // 给 BOX64_LD_LIBRARY_PATH 追加的路径
  static buildLdPaths(ctx: common.Context): string[] {
    const root: string = WineService.getRootDir(ctx);
    return [`${root}/lib/x86_64`, `${root}/lib/wine/x86_64-unix`];
  }
}