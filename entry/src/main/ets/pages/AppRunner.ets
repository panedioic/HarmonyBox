import wl from 'libentry.so';
import { OH2EVDEV, modMaskOf } from '../common/KeyMap';
import { mapMouseButton } from '../common/MouseMap';
import { WaylandService, WlBufferSize } from '../service/WaylandService';
import { common } from '@kit.AbilityKit';
import { ProcessManagerService } from '../service/ProcessManagerService';
import { WindowManagerService } from '../service/WindowManagerService';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'HBox_UI_Page_AppRunner';

@Entry({ storage: LocalStorage.getShared() })
@Component
struct AppRunner {
  // 从 loadContent 传入的 LocalStorage 读取
  @LocalStorageProp('appName') appName: string = '应用';
  @LocalStorageProp('instanceId') instanceId: string = '';
  @LocalStorageProp('appId') appId: string = '';
  @LocalStorageProp('clientId') clientId: string = '';
  @State scaleNumber: number = 1.0;
  @State surfacePxW: number = 1;
  @State surfacePxH: number = 1;
  private modMask: number = 0;
  // Resize drag 状态
  private resizing: boolean = false;
  private resizeEdges: number = 0;
  private resizeStartVpX: number = 0;
  private resizeStartVpY: number = 0;
  private lastVpX: number = 0;
  private lastVpY: number = 0;

  private static readonly LOADING_TIMEOUT_MS: number = 30_000;

  @State loadingTimedOut: boolean = false;
  private loadingTimer: number = -1;

  aboutToAppear(): void {
    this.scaleNumber = WaylandService.getInstance().getUiScale();

    // 注册自己的 resize begin listener (按 clientId 索引)
    WaylandService.getInstance().setHostResizeBeginListener(
      this.clientId,
      (edges: number): void => {
        this.resizing = true;
        this.resizeEdges = edges;
        this.resizeStartVpX = this.lastVpX;
        this.resizeStartVpY = this.lastVpY;
        hilog.info(0x0000, TAG,
          `HBOX_GUI_RESIZE_DRAG_RUNNER_BEGIN inst=${this.instanceId} `
            + `edges=0x${edges.toString(16)} `
            + `startVp=${this.lastVpX.toFixed(1)},${this.lastVpY.toFixed(1)}`
        );
      }
    );

    // ★ Loading 场景启动超时定时器
    if (this.clientId.length === 0) {
      this.loadingTimer = setTimeout((): void => {
        if (this.clientId.length === 0) {
          this.loadingTimedOut = true;
          hilog.warn(0x0000, TAG,`[AppRunner] loading timeout inst=${this.instanceId}`);
        }
        this.loadingTimer = -1;
      }, AppRunner.LOADING_TIMEOUT_MS) as number;
    }

    hilog.info(0x0000, TAG,
      `HBOX_APP_RUNNER_MOUNTED inst=${this.instanceId} app=${this.appName} `
        + `client=${this.clientId}`
    );
  }

  aboutToDisappear(): void {
    WaylandService.getInstance().setHostResizeBeginListener(this.clientId, null);
    if (this.loadingTimer >= 0) {
      clearTimeout(this.loadingTimer);
      this.loadingTimer = -1;
    }
  }

  private updateModifiers(ohKey: number, pressed: boolean): void {
    const mask: number = modMaskOf(ohKey);
    if (mask === 0) return;
    if (pressed) this.modMask |= mask; else this.modMask &= ~mask;
    wl.sendModifiers(this.clientId, this.modMask, 0, 0, 0); // ★
  }

  private cancelLoading(): void {
    hilog.info(0x0000, TAG,`[AppRunner] user cancelled loading inst=${this.instanceId}`);
    WindowManagerService.getInstance().destroyInstance(this.instanceId);
    // destroyInstance 会 terminateSelf, 页面随之销毁
  }

  private openLog(): void {
    hilog.info(0x0000, TAG,`[AppRunner] user opened log inst=${this.instanceId}`);
    WindowManagerService.getInstance().openLogForInstance(this.instanceId)
      .catch((e: BusinessError): void => {
        hilog.error(0x0000, TAG, `openLog failed: ${e.code} ${e.message}`);
      });
  }

  build() {
    Stack() {
      if (this.clientId.length > 0) {
        // ─── 正常渲染: 有 clientId, 挂 XComponent ───
        XComponent({
          id: `wl_xc_${this.instanceId}`,
          type: XComponentType.SURFACE,
          libraryname: 'entry'
        })
          .width('100%').height('100%')
          .onLoad((): void => {
            const xcId = `wl_xc_${this.instanceId}`;
            wl.bindXComponentClient(xcId, this.clientId);
            wl.sendMouseHover(this.clientId, true);
          })
      } else {
        // ─── Loading 状态 ───
        Column() {
          if (this.loadingTimedOut) {
            Text('⚠️').fontSize(36).margin({ bottom: 12 })
            Text(`${this.appName} 启动超时`)
              .fontSize(15).fontColor('#DDDDDD').margin({ bottom: 4 })
            Text('可能不是 Wayland 应用, 或启动失败.')
              .fontSize(12).fontColor('#888888').margin({ bottom: 20 })
          } else {
            LoadingProgress()
              .width(48).height(48)
              .color('#5DD46E')
              .margin({ bottom: 16 })
            Text(`正在启动 ${this.appName}...`)
              .fontSize(15).fontColor('#DDDDDD').margin({ bottom: 20 })
          }

          Row({ space: 12 }) {
            Text('打开日志')
              .fontSize(12).fontColor('#DDDDDD')
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .backgroundColor('#333333').borderRadius(6)
              .onClick((): void => { this.openLog(); })
            Text(this.loadingTimedOut ? '关闭' : '取消')
              .fontSize(12).fontColor('#DDDDDD')
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .backgroundColor('#333333').borderRadius(6)
              .onClick((): void => { this.cancelLoading(); })
          }
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    .focusable(true)
    .defaultFocus(true)
    .onKeyEvent((ev: KeyEvent): void => {
      if (this.clientId.length === 0) return;
      const code: number = OH2EVDEV[ev.keyCode] ?? 0;
      if (code === 0) return;
      const pressed: boolean = ev.type === KeyType.Down;
      this.updateModifiers(ev.keyCode, pressed);
      wl.sendKey(this.clientId, code, pressed);
    })
    .onMouse((ev: MouseEvent): void => {
      if (this.clientId.length === 0) return;
      this.lastVpX = ev.x;
      this.lastVpY = ev.y;

      if (this.resizing) {
        if (ev.action === MouseAction.Move || ev.action === MouseAction.Hover) {
          const dxPx: number = vp2px(ev.x - this.resizeStartVpX);
          const dyPx: number = vp2px(ev.y - this.resizeStartVpY);
          WaylandService.getInstance().notifyHostResizeDrag(
            this.resizeEdges, dxPx, dyPx);
        } else if (ev.action === MouseAction.Release) {
          this.resizing = false;
          WaylandService.getInstance().notifyHostResizeEnd();
        }
        return;
      }

      const sz: WlBufferSize =
        WaylandService.getInstance().getLatestBufferSize(this.clientId);
      if (sz.w <= 0 || sz.h <= 0 || this.surfacePxW <= 0 || this.surfacePxH <= 0) return;
      const x: number = vp2px(ev.x) * sz.w / this.surfacePxW;
      const y: number = vp2px(ev.y) * sz.h / this.surfacePxH;
      switch (ev.action) {
        case MouseAction.Move:
        case MouseAction.Hover:
          wl.sendMouseMove(this.clientId, x, y);
          break;
        case MouseAction.Press:
          wl.sendMouseMove(this.clientId, x, y);
          wl.sendMouseButton(this.clientId, mapMouseButton(ev.button), true);
          break;
        case MouseAction.Release:
          wl.sendMouseButton(this.clientId, mapMouseButton(ev.button), false);
          break;
        default:
          break;
      }
    })
    .onHover((isHover: boolean): void => {
      if (this.clientId.length === 0) return;
      wl.sendMouseHover(this.clientId, isHover);
    })
    .onAreaChange((_o: Area, n: Area): void => {
      this.surfacePxW = vp2px(n.width as number);
      this.surfacePxH = vp2px(n.height as number);
    })
  }
}