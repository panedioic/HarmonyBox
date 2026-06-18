import wl from 'libentry.so';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { Theme } from '../common/Theme';
import { WineService } from '../service/WineService';
import { LibStore } from '../service/LibStore';

const BOX64: string = '/data/service/hnp/bin/box64';

@Component
export struct DebugPage {
  @State output: string = '';
  @State running: boolean = false;
  @State copyHint: boolean = false;
  private scroller: Scroller = new Scroller();

  private append(s: string): void {
    this.output = this.output + s + '\n';
    setTimeout((): void => { this.scroller.scrollEdge(Edge.Bottom); }, 0);
  }

  private clear(): void { this.output = ''; }

  private existsLabel(p: string): string {
    try { return fs.accessSync(p) ? 'YES' : 'NO '; } catch (e) { return 'NO '; }
  }

  private readPart(path: string, head: number, tail: number): string {
    try {
      if (!fs.accessSync(path)) return '(not exist)';
      const text: string = fs.readTextSync(path);
      const lines: string[] = text.split('\n');
      if (head > 0) return lines.slice(0, head).join('\n');
      if (tail > 0) return lines.slice(-tail).join('\n');
      return text;
    } catch (e) {
      return `(read error: ${(e as Error).message})`;
    }
  }

  private async runCmd(exe: string, argv: string[], env: string[]): Promise<string> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const libPath: string = ctx.applicationInfo.nativeLibraryPath ?? '';
    try {
      const r = await wl.execCapture(exe, argv, libPath, env);
      const out: string = r.stdout || '';
      return `[exit=${r.code}]\n${out.trim()}`;
    } catch (e) {
      return `[exec error] ${JSON.stringify(e)}`;
    }
  }

  private buildEnv(logLevel: string): string[] {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const ldPaths: string[] = WineService.buildLdPaths(ctx);
    const x64: string = LibStore.getDir(ctx);
    if (x64) ldPaths.push(x64);
    const env: string[] = [
      `BOX64_LD_LIBRARY_PATH=${ldPaths.join(':')}`,
      `BOX64_LOG=${logLevel}`,
      `BOX64_NOBANNER=0`
    ];
    for (const e of WineService.buildLaunchEnv(ctx)) env.push(e);
    return env;
  }

  // ===== Sections =====
  private async secEnv(): Promise<void> {
    this.append('===== ENV =====');
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.append(`filesDir = ${ctx.filesDir}`);
    this.append(`nativeLibPath = ${ctx.applicationInfo.nativeLibraryPath ?? ''}`);
    this.append(`box64 exists = ${this.existsLabel(BOX64)}`);
    const wineRoot: string = WineService.getRootDir(ctx);
    this.append(`wineRoot = ${wineRoot}`);
    this.append(`wine bin    = ${this.existsLabel(WineService.getBinPath(ctx))}`);
    this.append(`wineserver  = ${this.existsLabel(`${wineRoot}/bin/wineserver`)}`);
    this.append(`prefix      = ${WineService.getPrefixDir(ctx)}`);

    this.append('\n-- /proc/self/status (head 12) --');
    this.append(this.readPart('/proc/self/status', 12, 0));
    this.append('\n-- /proc/self/attr/current --');
    this.append(this.readPart('/proc/self/attr/current', 0, 0));
    this.append('\n-- /proc/sys/vm/mmap_min_addr --');
    this.append(this.readPart('/proc/sys/vm/mmap_min_addr', 0, 0));
    this.append('\n-- /proc/self/maps (tail 25) --');
    this.append(this.readPart('/proc/self/maps', 0, 25));
  }

  private async secWineFiles(): Promise<void> {
    this.append('===== WINE FILES =====');
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const root: string = WineService.getRootDir(ctx);
    const checks: string[] = [
      `${root}/bin/wine`,
      `${root}/bin/wineserver`,
      `${root}/bin/wineboot`,
      `${root}/lib/x86_64/libgcc_s.so.1`,
      `${root}/lib/wine/x86_64-unix/ntdll.so`,
      `${root}/lib/wine/x86_64-unix/winewayland.drv.so`,
      `${root}/lib/wine/x86_64-windows/ntdll.dll`,
      `${root}/lib/wine/x86_64-windows/kernel32.dll`,
      `${root}/share/wine/wine.inf`
    ];
    for (const p of checks) this.append(`${this.existsLabel(p)} ${p}`);

    const xunix: string = `${root}/lib/wine/x86_64-unix`;
    this.append(`\n-- ls ${xunix} --`);
    try {
      if (fs.accessSync(xunix)) {
        const list: string[] = fs.listFileSync(xunix);
        this.append(`(${list.length} entries)`);
        const showN: number = Math.min(40, list.length);
        for (let i = 0; i < showN; i++) this.append(`  ${list[i]}`);
        if (list.length > 40) this.append(`  ...(+${list.length - 40} more)`);
      } else {
        this.append('(not exist)');
      }
    } catch (e) {
      this.append(`(error: ${(e as Error).message})`);
    }
  }

  private async secBox64(): Promise<void> {
    this.append('===== box64 --version =====');
    this.append(await this.runCmd(BOX64, [BOX64, '--version'], []));
  }

  private async secWineVersion(): Promise<void> {
    this.append('===== box64 wine --version =====');
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const wineBin: string = WineService.getBinPath(ctx);
    this.append(await this.runCmd(BOX64, [BOX64, wineBin, '--version'], this.buildEnv('1')));
  }

  private async secWineserver(): Promise<void> {
    this.append('===== box64 wineserver --version =====');
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const wineserver: string = `${WineService.getRootDir(ctx)}/bin/wineserver`;
    this.append(await this.runCmd(BOX64, [BOX64, wineserver, '--version'], this.buildEnv('1')));
  }

  private async secPrefix(): Promise<void> {
    this.append('===== PREFIX =====');
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const prefix: string = WineService.getPrefixDir(ctx);
    this.append(`prefix = ${prefix}`);
    try {
      const list: string[] = fs.listFileSync(prefix);
      this.append(`top entries: ${list.length}`);
      for (const e of list) this.append(`  ${e}`);
    } catch (e) {
      this.append(`(list err: ${(e as Error).message})`);
    }
    this.append('');
    this.append(`system.reg   = ${this.existsLabel(`${prefix}/system.reg`)}`);
    this.append(`drive_c      = ${this.existsLabel(`${prefix}/drive_c`)}`);
    this.append(`ntdll.dll    = ${this.existsLabel(`${prefix}/drive_c/windows/system32/ntdll.dll`)}`);
    this.append(`kernel32.dll = ${this.existsLabel(`${prefix}/drive_c/windows/system32/kernel32.dll`)}`);
  }

  private async secWineboot(): Promise<void> {
    this.append('===== box64 wine wineboot --init =====');
    this.append('(may take 30s+, stdout truncated to ~8KB)');
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const wineBin: string = WineService.getBinPath(ctx);
    this.append(await this.runCmd(
      BOX64, [BOX64, wineBin, 'wineboot', '--init'], this.buildEnv('1')
    ));
  }

  private async runOne(fn: () => Promise<void>): Promise<void> {
    if (this.running) return;
    this.running = true;
    try { await fn(); }
    catch (e) { this.append(`[unexpected] ${JSON.stringify(e)}`); }
    finally { this.running = false; }
  }

  private async runAll(): Promise<void> {
    if (this.running) return;
    this.running = true;
    this.clear();
    try {
      await this.secEnv();        this.append('');
      await this.secWineFiles();  this.append('');
      await this.secBox64();      this.append('');
      await this.secWineVersion();this.append('');
      await this.secWineserver(); this.append('');
      await this.secPrefix();
    } finally { this.running = false; }
  }

  private copy(): void {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.output);
    pasteboard.getSystemPasteboard().setData(data, (err): void => {
      if (!err) {
        this.copyHint = true;
        setTimeout((): void => { this.copyHint = false; }, 1500);
      }
    });
  }

  build() {
    Column() {
      Row() {
        Column({ space: 4 }) {
          Text('🔧 调试诊断')
            .fontSize(22).fontWeight(FontWeight.Bold)
          Text('排查 wine on box64。删除流程见文件头注释')
            .fontSize(11).fontColor('#999999')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        if (this.running) { LoadingProgress().width(20).height(20) }
      }
      .width('100%').margin({ bottom: 14 })

      Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap }) {
        Button('环境').fontSize(12).height(30)
          .padding({ left: 14, right: 14 }).margin({ right: 8, bottom: 8 })
          .backgroundColor(Theme.HM_BLUE).enabled(!this.running)
          .onClick((): void => { this.runOne((): Promise<void> => this.secEnv()); })
        Button('wine 文件').fontSize(12).height(30)
          .padding({ left: 14, right: 14 }).margin({ right: 8, bottom: 8 })
          .backgroundColor(Theme.HM_BLUE).enabled(!this.running)
          .onClick((): void => { this.runOne((): Promise<void> => this.secWineFiles()); })
        Button('box64').fontSize(12).height(30)
          .padding({ left: 14, right: 14 }).margin({ right: 8, bottom: 8 })
          .backgroundColor(Theme.HM_BLUE).enabled(!this.running)
          .onClick((): void => { this.runOne((): Promise<void> => this.secBox64()); })
        Button('wine --version').fontSize(12).height(30)
          .padding({ left: 14, right: 14 }).margin({ right: 8, bottom: 8 })
          .backgroundColor(Theme.HM_BLUE).enabled(!this.running)
          .onClick((): void => { this.runOne((): Promise<void> => this.secWineVersion()); })
        Button('wineserver').fontSize(12).height(30)
          .padding({ left: 14, right: 14 }).margin({ right: 8, bottom: 8 })
          .backgroundColor(Theme.HM_BLUE).enabled(!this.running)
          .onClick((): void => { this.runOne((): Promise<void> => this.secWineserver()); })
        Button('prefix').fontSize(12).height(30)
          .padding({ left: 14, right: 14 }).margin({ right: 8, bottom: 8 })
          .backgroundColor(Theme.HM_BLUE).enabled(!this.running)
          .onClick((): void => { this.runOne((): Promise<void> => this.secPrefix()); })
        Button('wineboot --init').fontSize(12).height(30)
          .padding({ left: 14, right: 14 }).margin({ right: 8, bottom: 8 })
          .backgroundColor('#F0F0F0').fontColor('#333333').enabled(!this.running)
          .onClick((): void => { this.runOne((): Promise<void> => this.secWineboot()); })
        Button('全部').fontSize(12).height(30)
          .padding({ left: 14, right: 14 }).margin({ right: 8, bottom: 8 })
          .backgroundColor('#5DD46E').enabled(!this.running)
          .onClick((): void => { this.runAll(); })
      }
      .width('100%').margin({ bottom: 4 })

      Row({ space: 8 }) {
        Button('清空').fontSize(12).height(28)
          .backgroundColor('#F0F0F0').fontColor('#333333')
          .onClick((): void => { this.clear(); })
        Button(this.copyHint ? '已复制' : '复制全部').fontSize(12).height(28)
          .backgroundColor(this.copyHint ? '#5DD46E' : '#F0F0F0')
          .fontColor(this.copyHint ? Color.White : '#333333')
          .onClick((): void => { this.copy(); })
      }
      .width('100%').margin({ bottom: 8 })

      Scroll(this.scroller) {
        Text(this.output.length > 0 ? this.output : '点击上方按钮开始诊断')
          .fontSize(11).fontFamily('monospace').fontColor('#E0E0E0')
          .width('100%').textAlign(TextAlign.Start)
          .copyOption(CopyOptions.LocalDevice)
      }
      .layoutWeight(1).width('100%').padding(12)
      .backgroundColor('#0E0E0E').borderRadius(8)
      .scrollBar(BarState.Auto).align(Alignment.TopStart)
    }
    .width('100%').height('100%')
    .alignItems(HorizontalAlign.Start)
  }
}