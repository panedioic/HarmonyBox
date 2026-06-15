import wl from 'libentry.so';
import { OH2EVDEV, modMaskOf, MOD_SHIFT, MOD_CTRL, MOD_ALT } from '../common/KeyMap';
import { mapMouseButton } from '../common/MouseMap';
import { WaylandService, WlBufferSize } from '../service/WaylandService';

@Entry
@Component
struct AppRunner {
  @State appName: string = '应用';
  @State surfaceW: number = 800;
  @State surfaceH: number = 600;
  @State scaleNumber: number = 1.0;
  @State surfacePxW: number = 1;
  @State surfacePxH: number = 1;

  // ArkTS 自己维护修饰键状态
  private modMask: number = 0;

  aboutToAppear(): void {
    const name = AppStorage.get<string>('currentAppName');
    if (name) this.appName = name;
    this.scaleNumber = WaylandService.getInstance().getUiScale();
  }

  private updateModifiers(ohKey: number, pressed: boolean): void {
    const mask: number = modMaskOf(ohKey);
    if (mask === 0) return;
    if (pressed) this.modMask |= mask;
    else this.modMask &= ~mask;
    wl.sendModifiers(this.modMask, 0, 0, 0);
  }

  build() {
    Stack() {
      XComponent({
        id: 'wl_xc',
        type: XComponentType.SURFACE,
        libraryname: 'entry'
      })
        .width('100%').height('100%')
        .onLoad((): void => {
          // 通知一次进入
          wl.sendMouseHover(true);
        })
    }
    .width('100%').height('100%')
    .backgroundColor(Color.Black)
    // ── 焦点 ──
    .focusable(true)
    .defaultFocus(true)
    // ── 键盘 ──
    .onKeyEvent((ev: KeyEvent): void => {
      const code: number = OH2EVDEV[ev.keyCode] ?? 0;
      if (code === 0) return;
      const pressed: boolean = ev.type === KeyType.Down;
      // 修饰键先发 modifiers,再发 key
      this.updateModifiers(ev.keyCode, pressed);
      wl.sendKey(code, pressed);
    })
    // ── 鼠标 ──
    .onMouse((ev: MouseEvent): void => {
      // 比例映射:不依赖固定 scale,自动适配最大化/手动 resize
      const sz: WlBufferSize = WaylandService.getInstance().getLatestBufferSize();
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