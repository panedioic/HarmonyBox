import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import wl from 'libentry.so';
import { ContainerInfo, ContainerConfig, ContainerType } from '../model/ContainerInfo';
import { InstallService } from './InstallService';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileUri } from '@kit.CoreFileKit';
import { resourceManager } from '@kit.LocalizationKit';

const TAG = 'HBox_UI_Svc_Container';

/**
 * DEBUG_MODE:
 *   true  -> 日志写文件 (LOGS_DIR), env 用硬编码 (方便排错)
 *   false -> 日志只走 hilog, env 从 info.config.envVars 读
 */
const DEBUG_MODE: boolean = true;

const CONFIG_FILE:    string = 'container.json';
const FONTS_DIR_NAME: string = 'fonts';
const FC_DIR_NAME:    string = 'fontconfig';
const FC_CONF_NAME:   string = 'fonts.conf';
const FC_CACHE_NAME:  string = 'cache';
const LOGS_DIR: string = '/storage/Users/currentUser/Share';

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

// fileIo readSync/writeSync 的 options 类型 (ArkTS 未导出,自定义匹配)
interface FsReadOpts {
  offset?:   number;
  length?:   number;
  position?: number;
}
interface FsWriteOpts {
  offset?:   number;
  length?:   number;
  encoding?: string;
}

export class ContainerService {
  private static readonly builtins: BuiltinEntry[] = [
    {
      id: 'builtin-linux-base',
      name: 'Linux 基础环境',
      desc: '基础 Linux 运行环境',
      type: ContainerType.LINUX,
      rawfileName: 'containers/builtin-linux-base.tar.zst'
    },
    {
      id: 'builtin-wine',
      name: 'Wine 基础环境',
      desc: '基础 Wine 运行环境',
      type: ContainerType.WINE,
      rawfileName: 'containers/builtin-wine.tar.zst'
    }
  ];
  // wineserver pid 记账 (containerId -> pid)
  private static wineserverPids: Map<string, number> = new Map();

  // ==============================================================
  //  基础
  // ==============================================================
  static getById(ctx: common.Context, id: string): ContainerInfo | null {
    if (!id) return null;
    const list: ContainerInfo[] = ContainerService.list(ctx);
    for (const c of list) { if (c.id === id) return c; }
    return null;
  }

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

  static getBuiltins(): BuiltinEntry[] {
    return ContainerService.builtins.slice();
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

      const cfg: ContainerConfig | null = ContainerService.readConfig(dir);
      if (!cfg) continue;
      const info: ContainerInfo = {
        id: name,
        path: dir,
        config: cfg,
        running: false,      // ← 先占位
        startTime: 0,
        pid: 0
      };
      info.running = ContainerService.isRunning(info);   // ← 再赋值
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
      if (!obj.envVars) obj.envVars = [];
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
  //  env / log 辅助
  // ==============================================================
  /** 合并 KEY=VAL 数组, override 中的 key 覆盖 base 中同名 key */
  private static mergeEnv(base: string[], override: string[]): string[] {
    if (override.length === 0) return base;
    const overrideKeys: string[] = [];
    for (const kv of override) {
      const eq: number = kv.indexOf('=');
      overrideKeys.push(eq >= 0 ? kv.substring(0, eq) : kv);
    }
    const out: string[] = [];
    for (const kv of base) {
      const eq: number = kv.indexOf('=');
      const k: string = eq >= 0 ? kv.substring(0, eq) : kv;
      if (overrideKeys.indexOf(k) < 0) out.push(kv);
    }
    for (const kv of override) out.push(kv);
    return out;
  }

  /**
   * DEBUG_MODE=true: 硬编码 env + 可选 override 覆盖同名 key
   * DEBUG_MODE=false: 直接返回 info.config.envVars (忽略 override,
   *                   生产模式下 env 完全由 config 决定)
   */
  private static buildEnv(info: ContainerInfo, debugOverride: string[] = []): string[] {
    if (DEBUG_MODE) {
      const wineRoot:       string = `${info.path}/wine`;
      const wineBinPath:    string = `${wineRoot}/bin/wine`;
      const wineServerPath: string = `${wineRoot}/bin/wineserver`;
      const winePrefixPath: string = `${info.path}/wineprefix`;
      const base: string[] = [
        `BOX64_LD_LIBRARY_PATH=${wineRoot}/lib/x86_64:${wineRoot}/lib/wine/x86_64-unix`,
        `BOX64_LOG=2`,
        `BOX64_NOBANNER=0`,
        `BOX64_REMAP_TRACE=1`,
        `WINEPREFIX=${winePrefixPath}`,
        `WINEDEBUG=+all`,
        `WINELOADER=${wineBinPath}`,
        `WINESERVER=${wineServerPath}`,
        `XDG_RUNTIME_DIR=${info.path}`,
        `HOME=${info.path}`,
        `TMPDIR=/data/storage/el2/base/cache`
      ];
      return ContainerService.mergeEnv(base, debugOverride);
    }
    return info.config.envVars.slice();
  }

  /** 打开日志文件. DEBUG_MODE=false 时返回 -1, 后续 log 调用会 no-op. */
  private static openLogFile(name: string): number {
    if (!DEBUG_MODE) return -1;
    try {
      if (!fs.accessSync(LOGS_DIR)) fs.mkdirSync(LOGS_DIR, true);
    } catch (_e) { /* ignore */ }
    const path: string = `${LOGS_DIR}/${name}`;
    try {
      const f: fs.File = fs.openSync(path,
        fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      hilog.info(0x0000, TAG, `[Container] log file: ${path}`);
      return f.fd;
    } catch (e) {
      hilog.error(0x0000, TAG, `[Container] openLogFile err: ${(e as Error).message}`);
      return -1;
    }
  }

  private static writeLogLine(fd: number, line: string): void {
    if (fd < 0) return;
    try {
      const buf: string = line.endsWith('\n') ? line : line + '\n';
      fs.writeSync(fd, buf);
    } catch (_e) { /* ignore */ }
  }

  private static closeLogFile(fd: number): void {
    if (fd < 0) return;
    try { fs.closeSync(fd); } catch (_e) { /* ignore */ }
  }

  // ==============================================================
  // 安装入口
  // ==============================================================
  static async install(ctx: common.Context, opts: InstallOptions): Promise<InstallResult> {
    if (!opts.name.trim()) {
      return { ok: false, error: '容器名称不能为空' };
    }
    const id: string = ContainerService.slug(opts.name);
    const dest: string = ContainerService.containerDir(ctx, id);

    try {
      if (fs.accessSync(dest)) {
        return { ok: false, error: `容器 "${id}" 已存在` };
      }
    } catch (_e) { /* not exists, ok */ }

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

  private static async installFromTar(
    _ctx: common.Context,
    opts: InstallOptions,
    id: string,
    dest: string
  ): Promise<InstallResult> {
    if (!opts.archiveUri) return { ok: false, error: '未选择 tar 文件' };
    const tarPath: string = new fileUri.FileUri(opts.archiveUri).path;
    // tar 的 -C 目标必须存在
    try {
      fs.mkdirSync(dest, true);
    } catch (e) {
      return { ok: false, error: `创建目标目录失败: ${(e as Error).message}` };
    }
    hilog.info(0x0000, TAG, `[import] extract ${tarPath} -> ${dest}`);
    const tarResult: InstallResult = await new Promise<InstallResult>((resolve): void => {
      let settled: boolean = false;
      const startTs: number = Date.now();
      const finish = (ok: boolean, msg: string): void => {
        if (settled) return;
        settled = true;
        const cost: number = (Date.now() - startTs) / 1000;
        hilog.info(0x0000, TAG,
          `[import] done ok=${ok} cost=${cost.toFixed(1)}s msg=${msg}`);
        resolve({ ok: ok, error: ok ? '' : msg });
      };
      const cb = (event: string, data: string): void => {
        if (event === 'out') {
          hilog.info(0x0000, TAG, `[import] tar: ${data}`);
        } else if (event === 'exit') {
          const code: number = parseInt(data, 10);
          if (code === 0) finish(true, 'exit=0');
          else finish(false, `tar exit=${code}`);
        }
      };
      let pid: number = 0;
      try {
        pid = wl.runCommand('tar',
          ['tar', 'xf', tarPath, '-C', dest], [], '', cb);
      } catch (e) {
        finish(false, `spawn exception: ${(e as Error).message}`);
        return;
      }
      if (pid <= 0) {
        finish(false, `spawn failed pid=${pid}`);
        return;
      }
      hilog.info(0x0000, TAG, `[import] pid=${pid}`);
    });
    if (!tarResult.ok) {
      ContainerService.rmDirSafe(dest);
      return { ok: false, error: 'tar 解压失败: ' + tarResult.error };
    }
    return ContainerService.finalizeInstall(dest, id, opts);
  }

  private static async installFromFolder(
    _ctx: common.Context,
    opts: InstallOptions,
    id: string,
    dest: string
  ): Promise<InstallResult> {
    if (!opts.folderUri) return { ok: false, error: '未选择文件夹' };
    const srcPath: string = new fileUri.FileUri(opts.folderUri).path;
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

  private static async installFromBuiltin(
    ctx: common.Context,
    opts: InstallOptions,
    id: string,
    dest: string
  ): Promise<InstallResult> {
    const entry: BuiltinEntry | undefined =
      ContainerService.builtins.find((b): boolean => b.id === opts.builtinId);
    if (!entry) return { ok: false, error: '未知的内置容器 ID' };

    try {
      fs.mkdirSync(dest, true);
    } catch (e) {
      return { ok: false, error: `创建目标目录失败: ${(e as Error).message}` };
    }

    // rawfile 存在 HAP 包里, tar 命令看不到, 先拷到 cacheDir
    hilog.info(0x0000, TAG, `[builtin] extracting rawfile: ${entry.rawfileName}`);
    const tmpPath: string = `${ctx.cacheDir}/builtin-${id}-${Date.now()}.tar.zst`;
    let rawfd: resourceManager.RawFileDescriptor | null = null;
    let dst: fs.File | null = null;
    try {
      rawfd = ctx.resourceManager.getRawFdSync(entry.rawfileName);
      hilog.info(0x0000, TAG, `[builtin] getRawFdSync succeed!`);
    } catch (e) {
      hilog.error(0x0000, TAG, `[builtin] getRawFdSync err: ${(e as Error).message}`);
      return { ok: false, error: `读取内置容器资源失败: ${(e as Error).message}` };
    }
    try {
      dst = fs.openSync(tmpPath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      hilog.info(0x0000, TAG, `[builtin] openSync succeed!`);
      const bufSize: number = 256 * 1024;
      const buf: ArrayBuffer = new ArrayBuffer(bufSize);
      let readPos: number = rawfd.offset;
      let remaining: number = rawfd.length;
      while (remaining > 0) {
        const toRead: number = remaining < bufSize ? remaining : bufSize;
        const readOpts: FsReadOpts = {
          offset: readPos,      // ← 从 position 改成 offset
          length: toRead
        };
        const n: number = fs.readSync(rawfd.fd, buf, readOpts);
        if (n <= 0) break;
        const writeOpts: FsWriteOpts = { length: n };  // 写用当前位置追加即可
        fs.writeSync(dst.fd, buf, writeOpts);
        readPos += n;
        remaining -= n;
      }
    } catch (e) {
      hilog.error(0x0000, TAG,
        `[builtin] copy rawfile err: ${(e as Error).message}`);
      try { fs.unlinkSync(tmpPath); } catch (_e) { /* ignore */ }
      return { ok: false, error: `内置容器资源复制失败: ${(e as Error).message}` };
    } finally {
      if (dst) { try { fs.closeSync(dst); } catch (_e) { /* ignore */ } }
      try {
        ctx.resourceManager.closeRawFdSync(entry.rawfileName);
      } catch (_e) { /* ignore */ }
    }

    hilog.info(0x0000, TAG, `[builtin] extract ${tmpPath} -> ${dest}`);

    const tarResult: InstallResult = await new Promise<InstallResult>((resolve): void => {
      let settled: boolean = false;
      const startTs: number = Date.now();

      const finish = (ok: boolean, msg: string): void => {
        if (settled) return;
        settled = true;
        const cost: number = (Date.now() - startTs) / 1000;
        hilog.info(0x0000, TAG,
          `[builtin] tar done ok=${ok} cost=${cost.toFixed(1)}s msg=${msg}`);
        resolve({ ok: ok, error: ok ? '' : msg });
      };

      const cb = (event: string, data: string): void => {
        if (event === 'out') {
          hilog.info(0x0000, TAG, `[builtin] tar: ${data}`);
        } else if (event === 'exit') {
          const code: number = parseInt(data, 10);
          if (code === 0) finish(true, 'exit=0');
          else finish(false, `tar exit=${code}`);
        }
      };

      let pid: number = 0;
      try {
        pid = wl.runCommand('tar', ['tar', 'xf', tmpPath, '-C', dest], [], '', cb);
      } catch (e) {
        finish(false, `spawn exception: ${(e as Error).message}`);
        return;
      }
      if (pid <= 0) {
        finish(false, `spawn failed pid=${pid}`);
        return;
      }
      hilog.info(0x0000, TAG, `[builtin] pid=${pid}`);
    });

    // 不管成败清临时文件
    try { fs.unlinkSync(tmpPath); } catch (_e) { /* ignore */ }

    if (!tarResult.ok) {
      ContainerService.rmDirSafe(dest);
      return { ok: false, error: 'tar 解压失败: ' + tarResult.error };
    }

    return ContainerService.finalizeInstall(dest, id, opts);
  }

  // 通用后处理: 检测 container.json + 合并用户输入 + 特殊类型初始化
  private static async finalizeInstall(
    dest: string,
    id: string,
    opts: InstallOptions
  ): Promise<InstallResult> {
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
    if (!cfg.envVars) cfg.envVars = [];

    // 字体自动配置
    if (ContainerService.hasFonts(dest)) {
      hilog.info(0x0000, TAG, `[Container] 发现 fonts 目录, 生成 fontconfig`);
      ContainerService.setupFontConfig(dest);
      const fontEnv: Record<string, string> =
        ContainerService.buildFontEnvVars(dest);
      const keys: string[] = Object.keys(fontEnv);
      const existing: string[] = Object.keys(cfg.envVars);
      for (const k of keys) {
        // 用户 tar 里已经写了这个 key 就不覆盖
        if (existing.indexOf(k) < 0) {
          cfg.envVars[k] = fontEnv[k];
        }
      }
    }

    if (!ContainerService.writeConfig(dest, cfg)) {
      ContainerService.rmDirSafe(dest);
      return { ok: false, error: '写入 container.json 失败' };
    }

    // 类型特化初始化
    if (cfg.type === ContainerType.WINE) {
      const info: ContainerInfo = {
        id: id, path: dest, config: cfg,
        running: false, startTime: 0, pid: 0
      };
      const initOk: boolean = await ContainerService.initWineContainer(info);
      if (!initOk) {
        // 允许初始化失败, 但标记 warning; 用户可后续手动修
        hilog.warn(0x0000, TAG, `[Container] wine 初始化未完成, 需要手动运行 wine.setup`);
      }
    } else if (cfg.type === ContainerType.LINUX) {
      // linux 容器暂时不做额外操作
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
  //  导出: tar cf tmp -C info.path .   然后 tmp -> URI
  // ==============================================================
  static async exportContainer(
    _ctx: common.Context,
    info: ContainerInfo,
    saveUri: string
  ): Promise<InstallResult> {
    const tarPath: string = new fileUri.FileUri(saveUri).path;

    let entries: string[] = [];
    try {
      entries = fs.listFileSync(info.path);
    } catch (e) {
      return { ok: false, error: `无法读取容器目录: ${(e as Error).message}` };
    }

    // wineprefix 会在 install 时由 initWineContainer 重建, 无需打包.
    // 如果未来支持"保留已装软件"备份模式, 再加开关.
    if (info.config.type === ContainerType.WINE) {
      entries = entries.filter((e): boolean => e !== 'wineprefix');
    }
    if (entries.length === 0) {
      return { ok: false, error: '容器目录为空' };
    }

    // --zstd: 压缩比 ~40%, 速度接近 gzip. bsdtar 内建, 无需外部程序.
    const argv: string[] = ['tar', '--zstd', '-cf', tarPath, '-C', info.path];
    for (const e of entries) argv.push(e);

    hilog.info(0x0000, TAG,
      `[export] pack ${entries.length} entries -> ${tarPath} (zstd)`);

    return new Promise<InstallResult>((resolve): void => {
      let settled: boolean = false;
      const startTs: number = Date.now();

      const finish = (ok: boolean, msg: string): void => {
        if (settled) return;
        settled = true;
        const cost: number = (Date.now() - startTs) / 1000;
        hilog.info(0x0000, TAG,
          `[export] done ok=${ok} cost=${cost.toFixed(1)}s msg=${msg}`);
        resolve({
          ok: ok,
          error: ok ? '' : msg,
          info: ok ? info : undefined
        });
      };

      const cb = (event: string, data: string): void => {
        if (event === 'out') {
          hilog.info(0x0000, TAG, `[export] tar: ${data}`);
        } else if (event === 'exit') {
          const code: number = parseInt(data, 10);
          if (code === 0) finish(true, 'exit=0');
          else finish(false, `tar exit=${code}`);
        }
      };

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
      hilog.info(0x0000, TAG, `[export] pid=${pid}`);
    });
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
  static async start(_ctx: common.Context, info: ContainerInfo): Promise<boolean> {
    if (info.config.type === ContainerType.WINE) {
      return await ContainerService.startWineserver(info);
    }
    if (info.config.type === ContainerType.LINUX) {
      // linux 容器暂时无操作
      return true;
    }
    return false;
  }

  static async stop(_ctx: common.Context, info: ContainerInfo): Promise<boolean> {
    if (info.config.type === ContainerType.WINE) {
      return await ContainerService.stopWineserver(info);
    }
    return true;
  }

  static isRunning(info: ContainerInfo): boolean {
    if (info.config.type === ContainerType.WINE) {
      return ContainerService.isWineserverRunning(info);
    }
    if (info.config.type === ContainerType.LINUX) {
      // linux 容器暂时无操作
      return true;
    }
    return false;
  }

  static isReady(info: ContainerInfo): boolean {
    if (info.config.type === ContainerType.WINE) {
      return ContainerService.isWinePrefixReady(info);
    }
    if (info.config.type === ContainerType.LINUX) {
      // linux 容器暂时无操作
      return true;
    }
    return false;
  }

  /**
   * 启动应用前的容器健康检查; 目前是 stub, 未来接容器内脚本
   * @todo 走容器内 health.sh
   */
  static async healthCheck(info: ContainerInfo): Promise<boolean> {
    hilog.info(0x0000, TAG, `[ContainerRunner] healthCheck stub for ${info.id}`);
    return true;
  }

  /**
   * 未来的容器脚本执行入口占位
   * @todo 通过 shell 执行容器内脚本
   */
  static async runScript(info: ContainerInfo, scriptRel: string, args: string[]): Promise<number> {
    hilog.warn(0x0000, TAG, `[ContainerRunner] runScript not implemented: ${info.id}/${scriptRel} args=${args.join(',')}`);
    return 0;
  }

  // ==============================================================
  //  wine
  // ==============================================================
  static async initWineContainer(info: ContainerInfo): Promise<boolean> {
    // 路径全部从容器目录拼, 不再用 config 里的可选字段, 避免调试期变量
    const wineRoot:       string = `${info.path}/wine`;
    const wineBinPath:    string = `${wineRoot}/bin/wine`;
    const wineServerPath: string = `${wineRoot}/bin/wineserver`;
    const winePrefixPath: string = `${info.path}/wineprefix`;

    hilog.info(0x0000, TAG, `[Container] === wine init start: ${info.id} ===`);
    hilog.info(0x0000, TAG, `[Container]   wineRoot   = ${wineRoot}`);
    hilog.info(0x0000, TAG, `[Container]   wineBin    = ${wineBinPath}`);
    hilog.info(0x0000, TAG, `[Container]   wineServer = ${wineServerPath}`);
    hilog.info(0x0000, TAG, `[Container]   winePrefix = ${winePrefixPath}`);

    // 1) 停旧 wineserver, 等 1s 让文件句柄释放
    if (ContainerService.isWineserverRunning(info)) {
      hilog.info(0x0000, TAG, `[Container] stop old wineserver`);
      await ContainerService.stopWineserver(info);
      await new Promise<void>((r): void => { setTimeout(r, 1000); });
    }

    // 2) 删除旧 prefix
    try {
      if (fs.accessSync(winePrefixPath)) {
        fs.rmdirSync(winePrefixPath);
        hilog.info(0x0000, TAG, `[Container] old prefix removed`);
      }
    } catch (e) {
      hilog.error(0x0000, TAG, `[Container] rm prefix err: ${(e as Error).message}`);
    }

    // 3) 清 box64-tmp (旧 socket/lock)
    const box64Tmp: string = '/data/storage/el2/base/cache/box64-tmp';
    try {
      if (fs.accessSync(box64Tmp)) {
        fs.rmdirSync(box64Tmp);
        hilog.info(0x0000, TAG, `[Container] box64-tmp cleaned`);
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, `[Container] rm box64-tmp err: ${(e as Error).message}`);
    }

    // 4) 新建 prefix 空目录
    try {
      fs.mkdirSync(winePrefixPath, true);
    } catch (e) {
      hilog.error(0x0000, TAG, `[Container] mkdir prefix err: ${(e as Error).message}`);
      return false;
    }
    hilog.info(0x0000, TAG, `[Container] wineprefix made succeed.`);

    // 5) native 预布置 (拷贝 x86_64-windows / i386-windows 到 drive_c)
    try {
      hilog.info(0x0000, TAG, `[Container] trying to run setupWinePrefix with ${winePrefixPath}, ${wineRoot}`);
      const ok: boolean = wl.setupWinePrefix(winePrefixPath, wineRoot);
      hilog.info(0x0000, TAG, `[Container] setupWinePrefix = ${ok ? 'OK' : 'FAIL'}`);
      if (!ok) return false;
    } catch (e) {
      hilog.error(0x0000, TAG, `[Container] setupWinePrefix err: ${(e as Error).message}`);
      return false;
    }

    // 6) 起 wineserver (env 写死)
    const wsOk: boolean = await ContainerService.startWineserver(info);
    if (!wsOk) {
      hilog.error(0x0000, TAG, `[Container] wineserver start failed`);
      return false;
    }

    // 7) wineboot --init, 等它退出
    const bootOk: boolean = await ContainerService.runWineboot(info);
    if (!bootOk) {
      hilog.error(0x0000, TAG, `[Container] wineboot failed`);
      return false;
    }

    hilog.info(0x0000, TAG, `[Container] === wine init done: ${info.id} ===`);
    return true;
  }

  private static async runWineboot(info: ContainerInfo,): Promise<boolean> {
    // 路径全部从容器目录拼, 不再用 config 里的可选字段, 避免调试期变量
    const wineRoot:       string = `${info.path}/wine`;
    const wineBinPath:    string = `${wineRoot}/bin/wine`;

    const ts: number = Date.now();
    const logFd: number = ContainerService.openLogFile(`wineboot-${info.id}-${ts}.log`);


    // DEBUG 用硬编码, 生产用 config.envVars
    const env: string[] = ContainerService.buildEnv(info);

    ContainerService.writeLogLine(logFd, `=== wineboot env ===`);
    for (const e of env) {
      ContainerService.writeLogLine(logFd, `ENV: ${e}`);
    }
    ContainerService.writeLogLine(logFd, `=== argv ===`);
    ContainerService.writeLogLine(logFd, `box64 ${wineBinPath} wineboot --init`);
    ContainerService.writeLogLine(logFd, `=== output ===`);

    const args: string[] = ['box64', wineBinPath, 'wineboot', '--init'];

    const timeoutMs: number = 240 * 1000;
    const startTs: number = Date.now();

    return new Promise<boolean>((resolve): void => {
      let settled: boolean = false;
      let ticker: number = 0;
      let pid: number = 0;

      const done = (ok: boolean, reason: string): void => {
        if (settled) return;
        settled = true;
        if (ticker !== 0) { clearInterval(ticker); ticker = 0; }
        ContainerService.writeLogLine(logFd, `=== ${reason}, ok=${ok} ===`);
        ContainerService.closeLogFile(logFd);
        hilog.info(0x0000, TAG, `[wineboot] ${reason}, ok=${ok}`);
        resolve(ok);
      };

      const cb = (event: string, data: string): void => {
        if (event === 'out') {
          ContainerService.writeLogLine(logFd, data);
        } else if (event === 'exit') {
          const code: number = parseInt(data, 10);
          const cost: number = (Date.now() - startTs) / 1000;
          done(code === 0, `child exit=${code} (${cost.toFixed(1)}s)`);
        }
      };

      try {
        pid = wl.runBox64('box64', args, env, info.path, cb);
      } catch (e) {
        done(false, `launch exception: ${(e as Error).message}`);
        return;
      }
      if (pid <= 0) { done(false, `launch failed pid=${pid}`); return; }
      ContainerService.writeLogLine(logFd, `[wineboot] pid=${pid}`);
      hilog.info(0x0000, TAG, `[wineboot] pid=${pid}, log -> logs/wineboot-${info.id}-${ts}.log`);

      ticker = setInterval((): void => {
        if (settled) { clearInterval(ticker); ticker = 0; return; }
        const dt: number = Date.now() - startTs;
        if (dt > timeoutMs) {
          hilog.warn(0x0000, TAG, `[wineboot] timeout, terminating pid=${pid}`);
          try { wl.terminate(pid); } catch (_e) { /* ignore */ }
          setTimeout((): void => {
            if (!settled) done(false, 'forced after timeout');
          }, 5000);
        }
      }, 5000) as number;
    });
  }

  /** prefix 是否已初始化 (system.reg 存在即视为已经 wineboot 过) */
  static isWinePrefixReady(info: ContainerInfo): boolean {
    const relPrefix: string = info.config.winePrefix ?? 'wineprefix';
    const winePrefixPath = `${info.path}/${relPrefix}`;
    try {
      return fs.accessSync(`${winePrefixPath}/system.reg`);
    } catch (_e) { return false; }
  }

  static isWineserverRunning(info: ContainerInfo): boolean {
    const pid: number | undefined = ContainerService.wineserverPids.get(info.id);
    return pid !== undefined && pid > 0;
  }

  private static async startWineserver(info: ContainerInfo): Promise<boolean> {
    // 路径全部从容器目录拼, 不再用 config 里的可选字段, 避免调试期变量
    const wineServerPath: string = `${info.path}/wine/bin/wineserver`;

    // check if wineserver is already running
    if (ContainerService.isWineserverRunning(info)) return true;

    try {
      if (!fs.accessSync(wineServerPath)) {
        hilog.error(0x0000, TAG, `[Container] wineserver 不存在: ${wineServerPath}`);
        return false;
      }
    } catch (_e) { return false; }

    // 日志文件
    const ts: number = Date.now();
    const logFd: number = ContainerService.openLogFile(`wineserver-${info.id}-${ts}.log`);

    // DEBUG 用硬编码, 生产用 config.envVars
    const env: string[] = ContainerService.buildEnv(info);

    hilog.info(0x0000, TAG, `[Container] wineserver env:`);
    for (const e of env) hilog.info(0x0000, TAG, `  ${e}`);

    const args: string[] = ['box64', wineServerPath, '-f', '-p'];

    try {
      wl.startProcMgr('/data/storage/el2/base/haps/entry/files/.procmgr.sock');

      let earlyExit: boolean = false;
      const cb = (event: string, data: string): void => {
        if (event === 'out') {
          ContainerService.writeLogLine(logFd, `[ws] ${data}`);
        } else if (event === 'exit') {
          earlyExit = true;
          ContainerService.writeLogLine(logFd, `[ws] EARLY EXIT code=${data}`);
          hilog.error(0x0000, TAG, `[Container] wineserver early exit code=${data}`);
        }
      };

      const pid: number = wl.runBox64('box64', args, env, info.path, cb);
      if (pid > 0) {
        ContainerService.wineserverPids.set(info.id, pid);
        hilog.info(0x0000, TAG, `[Container] wineserver started id=${info.id} pid=${pid}, waiting 2s...`);
        await new Promise<void>((res): void => { setTimeout(res, 2000); });
        if (earlyExit) {
          ContainerService.wineserverPids.delete(info.id);
          ContainerService.closeLogFile(logFd);
          return false;
        }
        // wineserver 保持运行, log fd 也不关闭 (由 stopWineserver 时兜底)
        // 但如果不好管理, 也可以在这里关掉, 后续 wineserver 的输出会丢
        // 稳妥做法: 关掉, 拿到启动阶段的 log 就够定位早死原因
        ContainerService.closeLogFile(logFd);
        return true;
      }
    } catch (e) {
      hilog.error(0x0000, TAG, `[Container] wineserver start err: ${(e as Error).message}`);
    }
    ContainerService.closeLogFile(logFd);
    return false;
  }

  private static async stopWineserver(info: ContainerInfo): Promise<boolean> {
    const pid: number | undefined =
      ContainerService.wineserverPids.get(info.id);
    if (pid !== undefined && pid > 0) {
      try { wl.terminate(pid); } catch (_e) { /* ignore */ }
      ContainerService.wineserverPids.delete(info.id);
    }
    return true;
  }

  // ==============================================================
  //  字体
  // ==============================================================
  /** 检测容器目录里是否存在非空 fonts 目录 */
  static hasFonts(containerDir: string): boolean {
    const fontsDir: string = `${containerDir}/${FONTS_DIR_NAME}`;
    try {
      if (!fs.accessSync(fontsDir)) return false;
      const entries: string[] = fs.listFileSync(fontsDir);
      return entries.length > 0;
    } catch (_e) { return false; }
  }

  /** 为容器生成 fontconfig/fonts.conf 和 cache 目录 */
  static setupFontConfig(containerDir: string): void {
    const fontsDir: string = `${containerDir}/${FONTS_DIR_NAME}`;
    const fcDir:    string = `${containerDir}/${FC_DIR_NAME}`;
    const cacheDir: string = `${fcDir}/${FC_CACHE_NAME}`;
    const confPath: string = `${fcDir}/${FC_CONF_NAME}`;

    try {
      if (!fs.accessSync(fcDir))    fs.mkdirSync(fcDir, true);
      if (!fs.accessSync(cacheDir)) fs.mkdirSync(cacheDir, true);
    } catch (_e) { /* ignore */ }

    // 清缓存: 目录名或路径变化后旧的 .cache-N 就无效了
    try {
      const entries: string[] = fs.listFileSync(cacheDir);
      for (const n of entries) {
        try { fs.unlinkSync(`${cacheDir}/${n}`); } catch (_e) { /* ignore */ }
      }
    } catch (_e) { /* ignore */ }

    const xml: string = ContainerService.buildFontConfigXml(fontsDir, cacheDir);
    try {
      const f = fs.openSync(confPath,
        fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, xml);
      fs.closeSync(f);
    } catch (_e) { /* ignore */ }
    hilog.info(0x0000, TAG, `[Container] fontconfig 已生成: ${confPath}`);
  }

  /** 字体相关环境变量 (绝对路径) */
  static buildFontEnvVars(containerDir: string): Record<string, string> {
    const fcDir:    string = `${containerDir}/${FC_DIR_NAME}`;
    const cacheDir: string = `${fcDir}/${FC_CACHE_NAME}`;
    const confPath: string = `${fcDir}/${FC_CONF_NAME}`;
    const env: Record<string, string> = {};
    env['FONTCONFIG_FILE'] = confPath;
    env['FONTCONFIG_PATH'] = fcDir;
    env['FC_CACHEDIR']     = cacheDir;
    return env;
  }

  /** 重生 fontconfig 并更新 container.json (导入路径变了后修复用) */
  static regenerateFontConfig(info: ContainerInfo): boolean {
    if (!ContainerService.hasFonts(info.path)) return false;
    ContainerService.setupFontConfig(info.path);
    const fontEnv: Record<string, string> =
      ContainerService.buildFontEnvVars(info.path);
    const keys: string[] = Object.keys(fontEnv);
    for (const k of keys) {
      info.config.envVars[k] = fontEnv[k];
    }
    return ContainerService.writeConfig(info.path, info.config);
  }

  private static buildFontConfigXml(fontDir: string, cacheDir: string): string {
    return `<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <dir>${fontDir}</dir>
  <cachedir>${cacheDir}</cachedir>

  <include ignore_missing="yes">/etc/fonts/conf.d</include>
  <include ignore_missing="yes">/usr/share/fontconfig/conf.avail</include>

  <match target="pattern">
    <test name="family"><string>mono</string></test>
    <edit name="family" mode="assign" binding="strong"><string>monospace</string></edit>
  </match>
  <match target="pattern">
    <test name="family"><string>sans</string></test>
    <edit name="family" mode="assign" binding="strong"><string>sans-serif</string></edit>
  </match>

  <alias>
    <family>monospace</family>
    <prefer>
      <family>DejaVu Sans Mono</family>
      <family>Liberation Mono</family>
      <family>Noto Sans Mono CJK SC</family>
      <family>Noto Sans Mono</family>
    </prefer>
  </alias>
  <alias>
    <family>sans-serif</family>
    <prefer>
      <family>DejaVu Sans</family>
      <family>Liberation Sans</family>
      <family>Noto Sans CJK SC</family>
      <family>Noto Sans</family>
    </prefer>
  </alias>
  <alias>
    <family>serif</family>
    <prefer>
      <family>DejaVu Serif</family>
      <family>Liberation Serif</family>
      <family>Noto Serif CJK SC</family>
      <family>Noto Serif</family>
    </prefer>
  </alias>

  <match target="font">
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="hinting"   mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
    <edit name="rgba"      mode="assign"><const>rgb</const></edit>
    <edit name="lcdfilter" mode="assign"><const>lcddefault</const></edit>
  </match>
</fontconfig>
`;
  }
}