export class Theme {
  static readonly HM_BLUE: string = '#007DFF';
  static readonly HM_BG: string = '#F1F3F5';
  static readonly HM_CARD: string = '#FFFFFF';
  static readonly TEXT_PRIMARY: string = '#000000';
  static readonly TEXT_SECONDARY: string = 'rgba(0,0,0,0.6)';
  static readonly TEXT_HINT: string = '#999999';
  static readonly BORDER_LIGHT: string = 'rgba(0,0,0,0.05)';
  static readonly RADIUS: number = 16;
  static readonly RADIUS_NAV: number = 12;
  static readonly SIDEBAR_WIDTH: number = 240;
}

export enum PageType {
  LIBRARY = 'library',
  INSTALL = 'install',
  SETTINGS = 'settings',
  FILES = 'files'
}