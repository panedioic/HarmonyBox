import wl from 'libentry.so';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { InstallService } from './InstallService';

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
    const env: string[] = WineService.buildLaunchEnv(ctx);
    try {
      const r = await wl.execCapture(BOX64_PATH, argv, libPath, env);
      const text: string = (r.stdout || '').trim();
      if (!text) return r.code === 0 ? '已安装' : `已安装 (exit ${r.code})`;
      return text.split('\n')[0].trim();
    } catch (e) {
      return '已安装 (版本读取失败)';
    }
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