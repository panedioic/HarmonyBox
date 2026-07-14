import { common, Want } from '@kit.AbilityKit';
import { Theme } from '../common/Theme';
import { ToolDetector, ToolStatus } from '../service/ToolDetector';
import { ToolEnvStore, Box64Env, UiPrefs } from '../model/ToolEnvStore';
import { LibStore, LibFile } from '../service/LibStore';
import { WaylandService } from '../service/WaylandService';
import { FontStore, FontFile } from '../service/FontStore';

interface ResourceStatus {
  id: string;
  name: string;
  url: string;
  installed: boolean;
  path: string;
  version: string;
  install: () => void;
  uninstall: () => void
}

@Component
export struct SettingsPage {
  @State tools: ToolStatus[] = [];
  @State hapsHowto: ToolStatus = ToolDetector.getHapsHowto();
  @State box64Env: Box64Env = ToolEnvStore.defaults();
  @State savedHint: string = '';
  @State libFiles: LibFile[] = [];
  @State libDir: string = '';
  @State uiScale: number = 1.0;
  @State fontFiles: FontFile[] = [];
  @State fontDir: string = '';
  @State useNativeDecor: boolean = true;
  @State wineStatus: ToolStatus = {
    id: 'wine', name: 'wine', url: '',
    installed: false, path: '', version: ''
  } as ToolStatus;
  @State wineBusy: boolean = false;
  @State installing: boolean = false;
  @State resources: ResourceStatus[] = [];

  private scaleOptions: number[] = [1.0, 1.25, 1.5, 2.0, 3.0];

  aboutToAppear(): void {
    this.refreshTools();
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.box64Env = ToolEnvStore.loadBox64(ctx);
    this.refreshLibs();
    const uiPrefs: UiPrefs = ToolEnvStore.loadUiPrefs(ctx);
    this.uiScale = uiPrefs.scale;
    this.useNativeDecor = uiPrefs.useNativeDecor;
    this.refreshFonts();
    this.resources = [];
  }

  refreshTools(): void {
    const list: ToolStatus[] = ToolDetector.probeAll();
    this.tools = list;
    this.fetchAllVersions();
  }

  async fetchAllVersions(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const specs = ToolDetector.getSpecs();
    for (let i = 0; i < this.tools.length; i++) {
      const t: ToolStatus = this.tools[i];
      if (!t.installed) continue;
      const spec = specs[i];
      const ver: string = await ToolDetector.fetchVersion(ctx, spec, t.path);
      // 触发 UI 更新需要重建数组
      const next: ToolStatus[] = this.tools.slice();
      next[i] = {
        id: t.id, name: t.name, url: t.url,
        installed: t.installed, path: t.path,
        version: ver
      } as ToolStatus;
      this.tools = next;
    }
  }

  openUrl(url: string): void {
    if (!url) return;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: url,
        entities: ['entity.system.browsable']
      };
      ctx.startAbility(want);
    } catch (e) {
      console.error(`openUrl failed: ${JSON.stringify(e)}`);
    }
  }

  saveBox64Env(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ToolEnvStore.saveBox64(ctx, this.box64Env);
    this.savedHint = '已保存,下次启动的应用会生效';
    setTimeout((): void => { this.savedHint = ''; }, 2000);
  }

  resetBox64Env(): void {
    this.box64Env = ToolEnvStore.defaults();
  }

  refreshLibs(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.libDir = LibStore.getDir(ctx);
    this.libFiles = LibStore.list(ctx);
  }

  async uploadLibs(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const n: number = await LibStore.pickAndAdd(ctx);
    if (n > 0) {
      this.refreshLibs();
      this.savedHint = `已添加 ${n} 个文件`;
      setTimeout((): void => { this.savedHint = ''; }, 2000);
    }
  }

  removeLib(name: string): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    LibStore.remove(ctx, name);
    this.refreshLibs();
  }

  clearLibs(): void {
    AlertDialog.show({
      title: '清空共享库',
      message: `将删除 ${this.libFiles.length} 个文件,无法撤销。`,
      primaryButton: {
        value: '取消', action: (): void => {}
      },
      secondaryButton: {
        value: '清空',
        fontColor: '#E64545',
        action: (): void => {
          const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
          LibStore.clear(ctx);
          this.refreshLibs();
        }
      }
    });
  }

  refreshFonts(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.fontDir = FontStore.getFontDir(ctx);
    this.fontFiles = FontStore.list(ctx);
  }

  async uploadFonts(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const n: number = await FontStore.pickAndAdd(ctx);
    if (n > 0) {
      this.refreshFonts();
      this.savedHint = `已添加 ${n} 个字体`;
      setTimeout((): void => { this.savedHint = ''; }, 2000);
    }
  }

  removeFont(name: string): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    FontStore.remove(ctx, name);
    this.refreshFonts();
  }

  clearFonts(): void {
    AlertDialog.show({
      title: '清空字体',
      message: `将删除 ${this.fontFiles.length} 个字体文件,无法撤销。`,
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: {
        value: '清空', fontColor: '#E64545',
        action: (): void => {
          const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
          FontStore.clear(ctx);
          this.refreshFonts();
        }
      }
    });
  }

  @Builder
  ScaleChip(s: number) {
    Text(`${Math.round(s * 100)}%`)
      .fontSize(13)
      .fontColor(this.uiScale === s ? Color.White : '#333333')
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .backgroundColor(this.uiScale === s ? Theme.HM_BLUE : '#F0F0F0')
      .borderRadius(8)
      .margin({ right: 10, bottom: 10 })
      .onClick((): void => {
        const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
        this.uiScale = s;
        const prefs: UiPrefs = { scale: s } as UiPrefs;
        ToolEnvStore.saveUiPrefs(ctx, prefs);
        WaylandService.getInstance().reloadUiPrefs(ctx);
        this.savedHint = `已设置缩放 ${Math.round(s * 100)}%`;
        setTimeout((): void => { this.savedHint = ''; }, 2000);
      })
  }

  @Builder
  ToolRow(t: ToolStatus) {
    Column({ space: 6 }) {
      Row() {
        Text(t.name)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)

        Text(t.installed ? '已安装' : '未安装')
          .fontSize(12)
          .fontColor(t.installed ? '#1A8F4D' : '#999999')
          .backgroundColor(t.installed ? '#E6F7EE' : '#F0F0F0')
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(6)
      }
      .width('100%')

      if (t.installed) {
        Text(`版本: ${t.version}`)
          .fontSize(12)
          .fontColor('#666666')
          .width('100%')
        Text(`路径: ${t.path}`)
          .fontSize(11)
          .fontColor('#AAAAAA')
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      Row({ space: 8 }) {
        Text(t.url || '暂未实现')
          .fontSize(12)
          .fontColor(t.url ? Theme.HM_BLUE : '#999999')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .onClick((): void => {
            if (t.url) this.openUrl(t.url);
          })
      }
      .width('100%')
    }
    .padding(14)
    .backgroundColor('#FAFAFA')
    .borderRadius(10)
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ bottom: 10 })
  }

  @Builder
  EnvRow(label: string, hint: string, value: string, onChange: (v: string) => void) {
    Column({ space: 6 }) {
      Row() {
        Text(label)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#333333')
          .layoutWeight(1)
        Text(hint)
          .fontSize(11)
          .fontColor('#999999')
      }
      .width('100%')

      TextInput({ text: value })
        .height(34)
        .fontSize(13)
        .onChange(onChange)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ bottom: 12 })
  }

  @Builder
  ResourceRow(t: ResourceStatus) {
    Column({ space: 6 }) {
      // —— Wine 子区块 ——
      Row() {
        Column({ space: 2 }) {
          Text(t.name)
            .fontSize(15).fontWeight(FontWeight.Medium)
          Text(t.installed
            ? `已安装  ${t.version} （沙箱路径: ${t.path}）`
            : `未安装`)
            .fontSize(11)
            .fontColor(t.installed ? '#1A8F4D' : '#999999')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button(t.installed ? '重新安装' : `安装 ${t.name}`)
          .width(t.installed ? '8%' : '14%')
          .fontSize(12).height(28).padding({ left: 14, right: 14 })
          .backgroundColor(Theme.HM_BLUE)
          .enabled(!this.wineBusy && !this.installing)
          .onClick((): void => { t.install(); })
        if (t.installed) {
          Button('卸载')
            .fontSize(12).height(28).margin({ left: 8 }).padding({ left: 14, right: 14 })
            .backgroundColor('#F0F0F0').fontColor('#333333')
            .onClick((): void => { t.uninstall(); })
        }
      }
      .width('100%')
      .padding(14)
      .backgroundColor('#FAFAFA').borderRadius(10)
      .margin({ bottom: 10 })
    }
  }

  build() {
    Scroll() {
      Column() {
        Text('环境配置')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .margin({ bottom: 8 })

        Text('此版本已内置 box64，其余工具可自行按需安装。')
          .fontSize(13)
          .fontColor('#666666')
          .margin({ bottom: 4 })

        // —— 窗口缩放 ——
        Text('窗口缩放')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .margin({ top: 16, bottom: 4 })

        Text('高分屏上窗口太小时使用。仅对新打开的应用窗口生效,需重新启动应用。')
          .fontSize(12)
          .fontColor('#999999')
          .margin({ bottom: 12 })

        Column() {
          Flex({
            direction: FlexDirection.Row,
            wrap: FlexWrap.Wrap,
            justifyContent: FlexAlign.Start
          }) {
            ForEach(this.scaleOptions, (s: number): void => {
              this.ScaleChip(s)
            }, (s: number): string => `scale_${s}`)
          }
          .width('100%')

          Text('放大原理:鸿蒙窗口尺寸 = buffer × 缩放比;EGL 在显示时双线性放大,文字会略糊。后续可加客户端原生缩放。')
            .fontSize(11)
            .fontColor('#AAAAAA')
            .margin({ top: 4 })
        }
        .padding(14)
        .backgroundColor('#FAFAFA')
        .borderRadius(10)
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        Divider().color('#EEEEEE').margin({ top: 14, bottom: 12 })

        Row() {
          Column({ space: 2 }) {
            Text('使用鸿蒙原生标题栏')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
            Text('关闭后变为沉浸式窗口,由客户端自带装饰提供标题栏与按钮')
              .fontSize(11)
              .fontColor('#999999')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.useNativeDecor })
            .selectedColor(Theme.HM_BLUE)
            .onChange((on: boolean): void => {
              this.useNativeDecor = on;
              const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
              const prefs: UiPrefs = {
                scale: this.uiScale,
                useNativeDecor: on
              } as UiPrefs;
              ToolEnvStore.saveUiPrefs(ctx, prefs);
              WaylandService.getInstance().reloadUiPrefs(ctx);
              this.savedHint = on ? '已启用原生标题栏' : '已切换为沉浸式窗口';
              setTimeout((): void => { this.savedHint = ''; }, 2000);
            })
        }
        .width('100%')

        Text('需要新打开的应用窗口才会生效。')
          .fontSize(11)
          .fontColor('#AAAAAA')
          .margin({ top: 6 })
      }
      .alignItems(HorizontalAlign.Start)
      .align(Alignment.Top)
      .width('100%')
    }
    .width('100%')
    .align(Alignment.Top)
    .layoutWeight(1)
  }
}