import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import wl, { TarResult } from 'libentry.so';
import {
  ContainerInfo, ContainerConfig, ContainerType, defaultContainerConfig
} from '../model/ContainerInfo';
import { InstallService } from './InstallService';

const CONFIG_FILE: string = 'container.json';

export interface InstallOptions {
  source: 'tar' | 'folder' | 'network' | 'builtin';
  archiveUri?: string;         // tar 路径
  folderUri?:  string;         // 文件夹 uri
  builtinId?:  string;         // 内置容器 id
  networkUrl?: string;         // 网络 url

  // 用户在 UI 里填的
  name:        string;
  description: string;
  type:        ContainerType;
}

export interface InstallResult {
  ok:      boolean;
  error:   string;
  info?:   ContainerInfo;
}

export interface BuiltinEntry {
  id: string;
  name: string;
  desc: string;
  type: ContainerType;
  rawfileName: string;    // rawfile/containers/xxx.tar
}

export class ContainerService {
  private static readonly builtins: BuiltinEntry[] = [
    {
      id: 'builtin-linux-base',
      name: 'Linux 基础环境',
      desc: '基础 Linux 运行环境',
      type: ContainerType.LINUX,
      rawfileName: 'containers/linux-base.tar'
    },
    {
      id: 'builtin-wine',
      name: 'Wine 基础环境',
      desc: '基础 Wine 运行环境',
      type: ContainerType.WINE,
      rawfileName: 'containers/wine.tar'
    }
  ];

  // ==============================================================
  // 目录管理
  // ==============================================================
  static rootDir(ctx: common.Context): string {
    const dir: string = `${ctx.filesDir}/containers`;
    try {
      if (!fs.accessSync(dir)) fs.mkdirSync(dir, true);
    } catch (_e) { /* ignore */ }
    return dir;
  }

  static containerDir(ctx: common.Context, id: string): string {
    return `${ContainerService.rootDir(ctx)}/${id}`;
  }

  // 把用户输入名字变成安全的目录名
  static slug(name: string): string {
    let s: string = name.trim().toLowerCase();
    s = s.replace(/[^a-z0-9_\-\u4e00-\u9fa5]/g, '-');
    s = s.replace(/-+/g, '-').replace(/^-|-$/g, '');
    if (s.length === 0) s = `container-${Date.now()}`;
    return s;
  }

  // ==============================================================
  // 扫描
  // ==============================================================
  static list(ctx: common.Context): ContainerInfo[] {
    const root: string = ContainerService.rootDir(ctx);
    const out: ContainerInfo[] = [];
    let names: string[] = [];
    try { names = fs.listFileSync(root); } catch (_e) { return out; }

    for (const name of names) {
      const dir: string = `${root}/${name}`;
      try {
        const st = fs.statSync(dir);
        if (!st.isDirectory()) continue;
      } catch (_e) { continue; }

      const cfg: ContainerConfig | null =
        ContainerService.readConfig(dir);
      if (!cfg) continue;
      const info: ContainerInfo = {
        id: name,
        path: dir,
        config: cfg,
        running: ContainerService.isRunning(cfg),
        startTime: 0,
        pid: 0
      };
      out.push(info);
    }
    // 按 createdAt 降序
    out.sort((a: ContainerInfo, b: ContainerInfo): number =>
    b.config.createdAt - a.config.createdAt);
    return out;
  }

  static readConfig(containerDir: string): ContainerConfig | null {
    const p: string = `${containerDir}/${CONFIG_FILE}`;
    try {
      if (!fs.accessSync(p)) return null;
      const txt: string = fs.readTextSync(p);
      const obj: ContainerConfig = JSON.parse(txt) as ContainerConfig;
      if (!obj || !obj.name || !obj.type) return null;
      if (!obj.envVars) obj.envVars = {} as Record<string, string>;
      return obj;
    } catch (_e) { return null; }
  }

  static writeConfig(containerDir: string, cfg: ContainerConfig): boolean {
    const p: string = `${containerDir}/${CONFIG_FILE}`;
    try {
      const f = fs.openSync(p, fs.OpenMode.WRITE_ONLY
        | fs.OpenMode.CREATE
        | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, JSON.stringify(cfg, null, 2));
      fs.closeSync(f);
      return true;
    } catch (_e) { return false; }
  }

  // ==============================================================
  // 安装入口
  // ==============================================================
  static async install(ctx: common.Context,
    opts: InstallOptions): Promise<InstallResult> {
    if (!opts.name.trim()) {
      return { ok: false, error: '容器名称不能为空' };
    }
    const id: string = ContainerService.slug(opts.name);
    const dest: string = ContainerService.containerDir(ctx, id);
    if (fs.accessSync(dest)) {
      return { ok: false, error: `容器 "${id}" 已存在` };
    }

    if (opts.source === 'tar') {
      return await ContainerService.installFromTar(ctx, opts, id, dest);
    }
    if (opts.source === 'folder') {
      return await ContainerService.installFromFolder(ctx, opts, id, dest);
    }
    if (opts.source === 'network') {
      return { ok: false, error: '网络安装暂未实现' };
    }
    if (opts.source === 'builtin') {
      return await ContainerService.installFromBuiltin(ctx, opts, id, dest);
    }
    return { ok: false, error: '未知的安装方式' };
  }

  private static async installFromTar(ctx: common.Context,
    opts: InstallOptions,
    id: string,
    dest: string): Promise<InstallResult> {
    if (!opts.archiveUri) return { ok: false, error: '未选择 tar 文件' };

    // 解压到 dest
    fs.mkdirSync(dest, true);
    let tarResult: TarResult;
    try {
      tarResult = await wl.tarExtract(opts.archiveUri, dest);
    } catch (e) {
      ContainerService.rmDirSafe(dest);
      return { ok: false, error: 'tar 解压失败: ' + (e as Error).message };
    }
    if (!tarResult.ok) {
      ContainerService.rmDirSafe(dest);
      return { ok: false, error: 'tar 解压失败: ' + tarResult.error };
    }

    return ContainerService.finalizeInstall(dest, id, opts);
  }

  private static async installFromFolder(ctx: common.Context,
    opts: InstallOptions,
    id: string,
    dest: string): Promise<InstallResult> {
    if (!opts.folderUri) return { ok: false, error: '未选择文件夹' };
    const srcPath: string = InstallService.uriToPath(opts.folderUri);
    if (!srcPath) {
      return { ok: false, error: '无法解析文件夹 URI' };
    }
    // 先做预检: 源目录里必须有 container.json, 避免复制完才发现无效
    const srcConfig: string = `${srcPath}/container.json`;
    try {
      if (!fs.accessSync(srcConfig)) {
        return {
          ok: false,
          error: '源文件夹缺少 container.json, 无法安装'
        };
      }
    } catch (_e) {
      return { ok: false, error: '无法访问源文件夹' };
    }
    // 复制
    try {
      InstallService.copyDirRec(srcPath, dest);
    } catch (e) {
      ContainerService.rmDirSafe(dest);
      return {
        ok: false,
        error: '复制文件夹失败: ' + (e as Error).message
      };
    }
    return ContainerService.finalizeInstall(dest, id, opts);
  }

  // 通用后处理: 检测 container.json + 合并用户输入 + 特殊类型初始化
  private static async finalizeInstall(dest: string,
    id: string,
    opts: InstallOptions): Promise<InstallResult> {
    const cfg: ContainerConfig | null = ContainerService.readConfig(dest);
    if (!cfg) {
      ContainerService.rmDirSafe(dest);
      return {
        ok: false,
        error: `安装包缺少 ${CONFIG_FILE}, 已回滚`
      };
    }

    // 用户输入覆盖
    cfg.name = opts.name.trim();
    if (opts.description.trim().length > 0) {
      cfg.description = opts.description.trim();
    }
    if (opts.type) cfg.type = opts.type;
    if (!cfg.createdAt) cfg.createdAt = Date.now();
    if (!cfg.envVars) cfg.envVars = {} as Record<string, string>;

    if (!ContainerService.writeConfig(dest, cfg)) {
      ContainerService.rmDirSafe(dest);
      return { ok: false, error: '写入 container.json 失败' };
    }

    // 类型特化初始化
    if (cfg.type === ContainerType.WINE) {
      const initOk: boolean = await ContainerService.initWineContainer(dest, cfg);
      if (!initOk) {
        // 允许初始化失败, 但标记 warning; 用户可后续手动修
        console.warn(`[Container] wine 初始化未完成, 需要手动运行 wine.setup`);
      }
    } else if (cfg.type === ContainerType.LINUX) {
      // TODO: linux 容器暂时不做额外操作
    }

    const info: ContainerInfo = {
      id: id, path: dest, config: cfg,
      running: false, startTime: 0, pid: 0
    };
    return { ok: true, error: '', info: info };
  }

  private static rmDirSafe(path: string): void {
    try {
      if (fs.accessSync(path)) fs.rmdirSync(path);
    } catch (_e) { /* ignore */ }
  }

  // ==============================================================
  // 卸载
  // ==============================================================
  static uninstall(ctx: common.Context, id: string): boolean {
    const dir: string = ContainerService.containerDir(ctx, id);
    try {
      if (fs.accessSync(dir)) fs.rmdirSync(dir);
      return true;
    } catch (_e) { return false; }
  }

  // ==============================================================
  // 启停 (stub, 需要接入现有 wineserver 通路)
  // ==============================================================
  static async start(ctx: common.Context,
    info: ContainerInfo): Promise<boolean> {
    if (info.config.type === ContainerType.WINE) {
      return await ContainerService.startWineserver(ctx, info);
    }
    if (info.config.type === ContainerType.LINUX) {
      // linux 容器暂时无操作
      return true;
    }
    return false;
  }

  static async stop(ctx: common.Context,
    info: ContainerInfo): Promise<boolean> {
    if (info.config.type === ContainerType.WINE) {
      return await ContainerService.stopWineserver(ctx, info);
    }
    return true;
  }

  private static isRunning(cfg: ContainerConfig): boolean {
    // TODO: 应查询实际 wineserver / 进程状态
    // 目前简化为 false, 由 page 层根据 pid 追踪
    return false;
  }

  // ── wine specific ─────────────────────────────────────────
  private static async initWineContainer(dest: string,
    cfg: ContainerConfig): Promise<boolean> {
    // 创建 prefix 目录占位
    const prefixRel: string = cfg.winePrefix ?? 'prefix';
    const prefixPath: string = `${dest}/${prefixRel}`;
    try {
      if (!fs.accessSync(prefixPath)) fs.mkdirSync(prefixPath, true);
    } catch (_e) { return false; }

    // TODO: 调 wineprefix::SetupWinePrefix(prefix, wineRoot)
    // 需要 wineRoot = dest + cfg.wineBin 的父目录
    // 目前只是标记 marker, 真正初始化留给启动时的 wine.setup 命令
    console.info(`[Container] wine 容器初始化占位完成: ${dest}`);
    return true;
  }

  private static async startWineserver(ctx: common.Context,
    info: ContainerInfo): Promise<boolean> {
    // TODO: 调用 native wineserver 启动
    // 需要设置 WINEPREFIX = info.path/info.config.winePrefix
    // 参考现有 shell 里的 wineserver.start 实现
    console.info(`[Container] TODO: start wineserver for "${info.id}"`);
    return true;
  }

  private static async stopWineserver(ctx: common.Context,
    info: ContainerInfo): Promise<boolean> {
    console.info(`[Container] TODO: stop wineserver for "${info.id}"`);
    return true;
  }

  static getBuiltins(): BuiltinEntry[] {
    return ContainerService.builtins.slice();
  }

  private static async installFromBuiltin(ctx: common.Context,
    opts: InstallOptions,
    id: string,
    dest: string): Promise<InstallResult> {
    const entry: BuiltinEntry | undefined =
      ContainerService.builtins.find((b): boolean => b.id === opts.builtinId);
    if (!entry) {
      return { ok: false, error: '未知的内置容器 ID' };
    }
    // TODO: 从 resourceManager.getRawFileContent 读出 tar 字节流,
    //   写入临时文件 (cacheDir/builtin_<id>.tar), 再走 tarExtract
    //   之后 finalizeInstall
    return {
      ok: false,
      error: `内置容器 "${entry.name}" 安装流程未实现`
    };
  }
}