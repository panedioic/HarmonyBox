export interface ExecResult {
  code: number;
  stdout: string;
}

export const startWaylandServer: (sockPath: string) => boolean;
export const launchClient: (exePath: string, argv: string[], sockPath: string, libPath: string) => number;
export const stopClient: () => void;
export const stopAll: () => void;
export const setStateCallback: (cb: (state: string) => void) => void;
export const execCapture: (exePath: string, argv: string[], libPath: string) => Promise<ExecResult>;