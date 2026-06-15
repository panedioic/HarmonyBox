export interface ExecResult {
  code: number;
  stdout: string;
}

export const startWaylandServer: (sockPath: string) => boolean;
export const stopClient: () => void;
export const stopAll: () => void;
export const setStateCallback: (cb: (state: string) => void) => void;
export const execCapture: (exePath: string, argv: string[], libPath: string) => Promise<ExecResult>;
export const stopCli: (pid: number) => void;
export const setCliCallback: (cb: (pid: number, event: string, data: string) => void) => void;

export const launchClient: (
  exePath: string, argv: string[], sockPath: string,
  libPath: string, extraEnv: string[]
) => number;

export const launchCli: (
  exePath: string, argv: string[], libPath: string,
  cwd: string, extraEnv: string[]
) => number;

export const sendKey: (evdevCode: number, pressed: boolean) => void;
export const sendModifiers: (depressed: number, latched: number, locked: number, group: number) => void;
export const sendMouseMove: (x: number, y: number) => void;
export const sendMouseButton: (button: number, pressed: boolean) => void;
export const sendMouseAxis: (dx: number, dy: number) => void;
export const sendMouseHover: (inside: boolean) => void;

export const setSizeCallback: (cb: (w: number, h: number) => void) => void;
export const getLatestSize: () => { w: number; h: number };

export const setMoveCallback: (cb: () => void) => void;

export const setMaximizeCallback: (cb: () => void) => void;
export const setUnmaximizeCallback: (cb: () => void) => void;
export const setResizeCallback: (cb: (edges: number) => void) => void;
export const requestClientResize: (w: number, h: number, maximized: boolean) => void;

export const setMinimizeCallback: (cb: () => void) => void;