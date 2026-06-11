import { window } from '@kit.ArkUI';

class RunningWindowManager {
  private windows: Map<string, window.Window> = new Map();

  has(name: string): boolean {
    return this.windows.has(name);
  }

  get(name: string): window.Window | undefined {
    return this.windows.get(name);
  }

  set(name: string, win: window.Window): void {
    this.windows.set(name, win);
  }

  remove(name: string): void {
    this.windows.delete(name);
  }
}

export const runningWindows: RunningWindowManager = new RunningWindowManager();