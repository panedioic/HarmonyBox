import wl from 'libentry.so';
import { OH2EVDEV, modMaskOf } from '../common/KeyMap';
import { mapMouseButton } from '../common/MouseMap';
import { WaylandService, WlBufferSize } from '../service/WaylandService';

@Entry({ storage: LocalStorage.getShared() })
@Component
struct AppRunner {
  // 从 loadContent 传入的 LocalStorage 读取
  @LocalStorageProp('appName')    appName:    string = '应用';
  @LocalStorageProp('instanceId') instanceId: string = '';
  @LocalStorageProp('appId')      appId:      string = '';
  @LocalStorageProp('clientId')   clientId:   string = '';

  @State scaleNumber: number = 1.0;
  @State surfacePxW:  number = 1;
  @State surfacePxH:  number = 1;

  private modMask: number = 0;

  // Resize drag 状态
  private resizing: boolean = false;
  private resizeEdges: number = 0;
  private resizeStartVpX: number = 0;
  private resizeStartVpY: number = 0;
  private lastVpX: number = 0;
  private lastVpY: number = 0;

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
        console.info(
          `HBOX_GUI_RESIZE_DRAG_RUNNER_BEGIN inst=${this.instanceId} `
            + `edges=0x${edges.toString(16)} `
            + `startVp=${this.lastVpX.toFixed(1)},${this.lastVpY.toFixed(1)}`
        );
      }
    );

    console.info(
      `HBOX_APP_RUNNER_MOUNTED inst=${this.instanceId} app=${this.appName} `
        + `client=${this.clientId}`
    );
  }

  aboutToDisappear(): void {
    WaylandService.getInstance().setHostResizeBeginListener(this.clientId, null);
  }

  private updateModifiers(ohKey: number, pressed: boolean): void {
    const mask: number = modMaskOf(ohKey);
    if (mask === 0) return;
    if (pressed) this.modMask |= mask;
    else this.modMask &= ~mask;
    // TODO(multi-client): 未来 wl.sendModifiers 加 clientId 参数
    wl.sendModifiers(this.modMask, 0, 0, 0);
  }

  build() {
    Stack() {
      XComponent({
        id: `wl_xc_${this.instanceId}`,
        type: XComponentType.SURFACE,
        libraryname: 'entry'
      })
        .width('100%').height('100%')
        .onLoad((): void => {
          // TODO(multi-client): wl.sendMouseHover(clientId, true)
          wl.sendMouseHover(true);
        })
    }
    .width('100%').height('100%')
    .backgroundColor(Color.Black)
    .focusable(true)
    .defaultFocus(true)
    .onKeyEvent((ev: KeyEvent): void => {
      const code: number = OH2EVDEV[ev.keyCode] ?? 0;
      if (code === 0) return;
      const pressed: boolean = ev.type === KeyType.Down;
      this.updateModifiers(ev.keyCode, pressed);
      // TODO(multi-client): wl.sendKey(clientId, code, pressed)
      wl.sendKey(code, pressed);
    })
    .onMouse((ev: MouseEvent): void => {
      this.lastVpX = ev.x;
      this.lastVpY = ev.y;

      // Resize drag 接管
      if (this.resizing) {
        if (ev.action === MouseAction.Move || ev.action === MouseAction.Hover) {
          const dxPx: number = vp2px(ev.x - this.resizeStartVpX);
          const dyPx: number = vp2px(ev.y - this.resizeStartVpY);
          WaylandService.getInstance().notifyHostResizeDrag(
            this.resizeEdges, dxPx, dyPx);
        } else if (ev.action === MouseAction.Release) {
          console.info(`HBOX_GUI_RESIZE_DRAG_RUNNER_END inst=${this.instanceId}`);
          this.resizing = false;
          WaylandService.getInstance().notifyHostResizeEnd();
        }
        return;
      }

      // 普通模式: vp → buffer 比例映射
      const sz: WlBufferSize =
        WaylandService.getInstance().getLatestBufferSize(this.clientId);
      if (sz.w <= 0 || sz.h <= 0 || this.surfacePxW <= 0 || this.surfacePxH <= 0) return;
      const x: number = vp2px(ev.x) * sz.w / this.surfacePxW;
      const y: number = vp2px(ev.y) * sz.h / this.surfacePxH;
      switch (ev.action) {
        case MouseAction.Move:
        case MouseAction.Hover:
          wl.sendMouseMove(x, y);
          break;
        case MouseAction.Press:
          wl.sendMouseMove(x, y);
          wl.sendMouseButton(mapMouseButton(ev.button), true);
          break;
        case MouseAction.Release:
          wl.sendMouseButton(mapMouseButton(ev.button), false);
          break;
        default:
          break;
      }
    })
    .onHover((isHover: boolean): void => {
      wl.sendMouseHover(isHover);
    })
    .onAreaChange((_o: Area, n: Area): void => {
      this.surfacePxW = vp2px(n.width as number);
      this.surfacePxH = vp2px(n.height as number);
    })
  }
}