import wl from 'libentry.so';
import { common } from '@kit.AbilityKit';
import { AppInfo, LaunchMode, resolveExecPath, ExecPathType } from '../model/AppInfo';
import { ContainerInfo, ContainerType } from '../model/ContainerInfo';
import { ContainerService } from './ContainerService';
import { WindowManagerService } from './WindowManagerService';
import { AppRegistry } from '../model/AppRegistry';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'HBox_UI_Svc_ProcessManager';

// =========================================================
// 公开接口
// =========================================================

export interface LaunchOptions {
  launchMode: LaunchMode;
  /** shortcut Ability 场景: Ability 已经存在, 复用 instanceId, 跳过 prepareGuiHost / createLogWindow */
  reuseInstanceId?: string;
}

export interface LaunchResult {
  ok: boolean;
  instanceId: string;
  errorMsg: string;
}

export interface ProcessSubscriber {
  onLine: (line: string) => void;
  onExit: (code: number) => void;
}

export interface SpawnOptions {
  exeAbsPath: string;
  argv: string[];
  env: string[];
  cwd: string;
}

export interface SpawnResult {
  pid: number;
  errorMsg: string;
}

// =========================================================
// 内部
// =========================================================

const MAX_BUFFER_LINES: number = 5000;
const SOCK_PATH: string = '/data/storage/el2/base/haps/entry/files/.procmgr.sock';

export class ProcessManagerService {
  private static instance: ProcessManagerService | null = null;

  static getInstance(): ProcessManagerService {
    if (!ProcessManagerService.instance) {
      ProcessManagerService.instance = new ProcessManagerService();
    }
    return ProcessManagerService.instance;
  }

  private ctx: common.Context | null = null;             // ← 类型从 UIAbilityContext 改成 Context
  private uiCtx: common.UIAbilityContext | null = null;  // ← 新增

  // pid 输出缓冲与订阅
  private buffers: Map<number, string[]> = new Map();
  private subscribers: Map<number, ProcessSubscriber> = new Map();
  private exited: Map<number, number> = new Map();

  // instance 序列号
  private instanceSeq: number = 0;

  // pid <-> instanceId 映射
  private pidToInstance: Map<number, string> = new Map();
  private instanceToPid: Map<string, number> = new Map();

  // toast 回调
  private toastFn: ((msg: string, dur: number) => void) | null = null;

  /** shortcut Ability 用: 预分配 instanceId, 之后 attach 自己 + 传 reuseInstanceId 调 launchApp */
  allocateInstanceId(): string {
    return `inst-${++this.instanceSeq}`;
  }

  // =========================================================
  // lifecycle
  // =========================================================

  initStage(ctx: common.Context): void {
    this.ctx = ctx;
    wl.startProcMgr(SOCK_PATH);
  }

  initUI(ctx: common.UIAbilityContext): void {
    this.uiCtx = ctx;
  }

  /** @deprecated 使用 initStage / initUI 替代 */
  init(ctx: common.UIAbilityContext): void {
    this.initStage(ctx);
    this.initUI(ctx);
  }

  setToastFn(fn: ((msg: string, dur: number) => void) | null): void {
    this.toastFn = fn;
  }

  private toast(msg: string, dur: number = 1500): void {
    if (this.toastFn) this.toastFn(msg, dur);
  }

  // =========================================================
  // 对外: 启动应用 (从 Index 调用)
  // =========================================================

  async launchApp(app: AppInfo, opts: LaunchOptions): Promise<LaunchResult> {
    if (!this.ctx) {
      return { ok: false, instanceId: '', errorMsg: 'context 未初始化' };
    }
    const ctx = this.ctx;

    // 1. 找容器
    if (!app.containerId) {
      this.toast('该应用未关联容器, 请编辑应用重新指定', 2500);
      return { ok: false, instanceId: '', errorMsg: '未关联容器' };
    }
    const container: ContainerInfo | null = ContainerService.getById(ctx, app.containerId);
    if (!container) {
      this.toast(`未找到容器 "${app.containerId}", 请检查是否已删除`, 2500);
      return { ok: false, instanceId: '', errorMsg: '容器不存在' };
    }

    // 2. 容器健康检查
    const healthy: boolean = await ContainerService.healthCheck(container);
    if (!healthy) {
      this.toast('容器健康检查未通过', 2000);
      return { ok: false, instanceId: '', errorMsg: '容器健康检查失败' };
    }
    if (!ContainerService.isReady(container)) {
      this.toast('Wine prefix 未初始化, 请先在容器管理中初始化 (如果您刚刚安装容器，可能需要等待大约 2 分钟初始化)', 5000);
      return { ok: false, instanceId: '', errorMsg: 'wine prefix 未初始化' };
    }

    // 3. 确保基础设施
    if (!wl.ensureBox64TmpDir()) {
      hilog.error(0x0000, TAG, 'HBOX_PMS ensureBox64TmpDir failed');
    }

    // 4. 判断容器是否已经启动（暂时写的是判断wineserver是否运行，未来改成判断容器是否运行）
    if (!ContainerService.isWineserverRunning(container) && container.config.type === ContainerType.WINE) {
      const ok: boolean = await ContainerService.start(ctx, container);
      if (!ok) {
        this.toast('wineserver 启动失败', 2500);
        return { ok: false, instanceId: '', errorMsg: 'wineserver 启动失败' };
      }
    }

    // 5. 拼装参数
    const installRoot: string = `${ctx.filesDir}/${app.installDir}`;
    const userExe: string = resolveExecPath(app, container, ctx.filesDir);
    const isBare: boolean = app.execPathType === ExecPathType.BARE;
    const userArgs: string[] = (app.config.args || '').split(/\s+/).filter((s: string): boolean => s.length > 0);
    const userEnvs: string[] = this.parseAppEnv(app.config.envVars, ctx, installRoot);
    const containerEnv: string[] = [...(container.config.envVars || [])];

    // 6. 生成或复用 instanceId
    let instanceId: string;
    if (opts.reuseInstanceId) {
      instanceId = opts.reuseInstanceId;
    } else {
      instanceId = `inst-${++this.instanceSeq}`;
    }
    WindowManagerService.getInstance().registerPending(instanceId, app.name, app.id);
    const identityEnv: string[] = [`HBOX_INSTANCE_ID=${instanceId}`];

    // 7. 通用环境变量 (未来搬到容器配置)
    const filesDir: string = ctx.filesDir;
    const ldPaths: string[] = [installRoot, `${installRoot}/lib`];
    const commonEnv: string[] = [
      `WAYLAND_DISPLAY=wl-sock`,
      `XDG_RUNTIME_DIR=${filesDir}`,
      `HOME=${filesDir}`,
      `BOX64_LOG=0`,
      `BOX64_NOBANNER=1`,
      `BOX64_DYNAREC=1`,
      `BOX64_LD_LIBRARY_PATH=${ldPaths.join(':')}`,
    ];

    // 8. 组装启动命令
    // BARE 场景: 路径原样传给 wine (或 PATH), 让下层去找
    // 非 BARE: 使用 resolveExecPath 得到的绝对路径
    let exeAbs: string;
    let launchArgs: string[];
    let launchEnvs: string[];

    if (container.config.type === ContainerType.WINE) {
      const wineBinPath: string    = `${container.path}/wine/bin/wine`;
      const wineServerPath: string = `${container.path}/wine/bin/wineserver`;
      const winePrefixPath: string = `${container.path}/wineprefix`;
      const wineEnv: string[] = [
        `WINEPREFIX=${winePrefixPath}`,
        `WINELOADER=${wineBinPath}`,
        `WINESERVER=${wineServerPath}`,
        `WINEDEBUG=-all`,
        `BOX64_NOBANNER=1`,
      ];
      exeAbs = isBare ? wineBinPath : userExe;   // spawn 需要一个有效的绝对路径做 execveat
      launchArgs = ['box64', wineBinPath, userExe, ...userArgs];
      launchEnvs = [...containerEnv, ...wineEnv, ...userEnvs, ...identityEnv];

    } else if (container.config.type === ContainerType.LINUX) {
      exeAbs = isBare ? 'box64' : userExe;       // BARE 时无有效路径, 让 runCommand 走 PATH
      launchArgs = ['box64', userExe, ...userArgs];
      launchEnvs = [...commonEnv, ...containerEnv, ...userEnvs, ...identityEnv];

    } else {
      this.toast(`暂不支持容器类型 ${container.config.type}`, 2000);
      return { ok: false, instanceId: '', errorMsg: '不支持的容器类型' };
    }

    // (原第 8 步的重复 registerPending 已删除)

    // 9. GUI-first: spawn 前先拉起 AppRunnerAbility 展 loading
    hilog.info(0x0000, TAG,
      `[PMS] launch inst=${instanceId} mode=${opts.launchMode} `
        + `reuse=${opts.reuseInstanceId ?? '(none)'}`);
    if (opts.launchMode === LaunchMode.GUI && !opts.reuseInstanceId) {
      try {
        hilog.info(0x0000, TAG, `[PMS] prepareGuiHost invoked inst=${instanceId}`);
        await WindowManagerService.getInstance().prepareGuiHost(instanceId, app.name, app.id);
      } catch (e) {
        hilog.warn(0x0000, TAG, `[PMS] prepareGuiHost failed: ${(e as Error).message}`);
      }
    }

    this.toast(`正在启动 ${app.name}...`, 1200);

    // 10. spawn (保留原有逻辑)
    let pid: number = -1;
    try {
      const cb = (event: string, data: string): void => {
        this.handleStreamEvent(pid, event, data);
      };
      pid = wl.runCommand(exeAbs, launchArgs, launchEnvs, installRoot, cb, 'box64');
    } catch (e) {
      pid = -1;
    }
    if (pid <= 0) {
      WindowManagerService.getInstance().cancelPending(instanceId);
      if (!opts.reuseInstanceId && opts.launchMode === LaunchMode.GUI) {
        // 只有非 reuse 场景才主动 destroy (loading 窗口是 launchApp 拉起的);
        // reuse 场景下 loading 窗口归调用方 (shortcut Ability) 管
        WindowManagerService.getInstance().destroyInstance(instanceId);
      }
      this.toast(`${app.name} 启动失败: (fork/exec)`, 2500);
      return { ok: false, instanceId: '', errorMsg: '启动失败: (fork/exec)' };
    }

    // 10. 记录映射
    this.pidToInstance.set(pid, instanceId);
    this.instanceToPid.set(instanceId, pid);

    // 11. 通知 WindowManagerService 绑定 pid
    WindowManagerService.getInstance().bindPid(instanceId, pid);

    // 12. 订阅进程退出
    this.subscribe(pid, {
      onLine: (): void => { /* 日志窗口通过外部 subscribe 消费 */ },
      onExit: (code: number): void => {
        WindowManagerService.getInstance().onProcessExit(instanceId, code);
        this.pidToInstance.delete(pid);
        this.instanceToPid.delete(instanceId);
      }
    });

    // 13. CLI-first 立即开日志窗 (GUI-first 由 wayland 触发 startAbility)
    // (reuse 时跳过)
    if (opts.launchMode === LaunchMode.CLI && !opts.reuseInstanceId) {
      await WindowManagerService.getInstance().createLogWindow(instanceId, app.name, pid);
    }

    return { ok: true, instanceId, errorMsg: '' };
  }

  /** shortcut / Ability 内部触发: 按 appId 查 AppInfo 后启动 */
  async launchAppById(appId: string, opts: LaunchOptions): Promise<LaunchResult> {
    if (!this.ctx) {
      return { ok: false, instanceId: '', errorMsg: 'context 未初始化' };
    }
    const app: AppInfo | null = AppRegistry.getById(this.ctx, appId);
    if (!app) {
      this.toast(`未找到应用 ${appId}`, 2500);
      return { ok: false, instanceId: '', errorMsg: `未找到应用 ${appId}` };
    }
    return this.launchApp(app, opts);
  }

  // =========================================================
  // 对外: 进程管理
  // =========================================================

  subscribe(pid: number, sub: ProcessSubscriber): string[] {
    this.subscribers.set(pid, sub);
    const exitCode: number | undefined = this.exited.get(pid);
    if (exitCode !== undefined) {
      setTimeout((): void => { sub.onExit(exitCode); }, 0);
    }
    const buf: string[] | undefined = this.buffers.get(pid);
    return buf ? buf.slice() : [];
  }

  unsubscribe(pid: number): void {
    this.subscribers.delete(pid);
  }

  terminate(pid: number): void {
    if (pid <= 0) return;
    try { wl.terminate(pid); } catch (e) { /* ignore */ }
  }

  terminateByInstance(instanceId: string): void {
    const pid: number | undefined = this.instanceToPid.get(instanceId);
    if (pid !== undefined && pid > 0) {
      this.terminate(pid);
    }
  }

  clear(pid: number): void {
    this.buffers.delete(pid);
    this.exited.delete(pid);
  }

  isRunning(pid: number): boolean {
    return !this.exited.has(pid);
  }

  getPidByInstance(instanceId: string): number {
    return this.instanceToPid.get(instanceId) ?? -1;
  }

  // =========================================================
  // 对外: 关闭某 app 的所有实例
  // =========================================================

  closeAllOfApp(appId: string): void {
    WindowManagerService.getInstance().destroyAllOfApp(appId);
  }

  // =========================================================
  // private: 参数构建
  // =========================================================

  private parseAppEnv(envText: string, ctx: common.Context, appDir: string): string[] {
    if (!envText) return [];
    const filesDir: string = ctx.filesDir;
    const out: string[] = [];
    const parts: string[] = envText.split(/[;\n\r]+/);
    for (const raw of parts) {
      const line: string = raw.trim();
      if (!line || !line.includes('=')) continue;
      const expanded: string = line
        .replace(/\${APP_DIR}/g, appDir)
        .replace(/\${FILES_DIR}/g, filesDir);
      out.push(expanded);
    }
    return out;
  }

  // =========================================================
  // private: 流式输出处理
  // =========================================================

  private handleStreamEvent(pid: number, event: string, data: string): void {
    if (event === 'out') {
      let buf: string[] | undefined = this.buffers.get(pid);
      if (!buf) {
        buf = [];
        this.buffers.set(pid, buf);
      }
      buf.push(data);
      if (buf.length > MAX_BUFFER_LINES) {
        buf.splice(0, buf.length - MAX_BUFFER_LINES);
      }
      const sub = this.subscribers.get(pid);
      if (sub) sub.onLine(data);
    } else if (event === 'exit') {
      const code: number = parseInt(data, 10);
      const realCode: number = isNaN(code) ? -1 : code;
      this.exited.set(pid, realCode);
      const sub = this.subscribers.get(pid);
      if (sub) sub.onExit(realCode);
    }
  }
}