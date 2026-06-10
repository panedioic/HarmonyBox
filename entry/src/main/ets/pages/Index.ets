import { Theme, PageType } from '../common/Theme';
import { AppInfo } from '../model/AppInfo';
import { Sidebar } from '../components/Sidebar';
import { LibraryPage } from '../components/LibraryPage';
import { InstallPage } from '../components/InstallPage';
import { SettingsPage } from '../components/SettingsPage';
import { FilesPage } from '../components/FilesPage';
import { SplashScreen } from '../components/SplashScreen';

@Entry
@Component
struct Index {
  @State currentPage: string = PageType.LIBRARY;
  @State splashVisible: boolean = false;
  @State splashAppName: string = '';
  @State installedApps: AppInfo[] = [
    new AppInfo('微信 (Windows)', '💬'),
    new AppInfo('Steam', '🎮'),
    new AppInfo('Notepad++', '📝')
  ];

  launchApp = (name: string): void => {
    this.splashAppName = name;
    this.splashVisible = true;
  }

  closeSplash = (): void => {
    this.splashVisible = false;
  }

  addApp = (name: string): void => {
    this.installedApps.push(new AppInfo(name, '📦'));
    this.currentPage = PageType.LIBRARY;
  }

  @Builder
  PageContent() {
    if (this.currentPage === PageType.LIBRARY) {
      LibraryPage({ apps: $installedApps, onLaunch: this.launchApp })
    } else if (this.currentPage === PageType.INSTALL) {
      InstallPage({ onInstalled: this.addApp })
    } else if (this.currentPage === PageType.SETTINGS) {
      SettingsPage()
    } else if (this.currentPage === PageType.FILES) {
      FilesPage()
    }
  }

  build() {
    Stack() {
      Row() {
        Sidebar({ currentPage: $currentPage })

        Column() {
          this.PageContent()
        }
        .layoutWeight(1)
        .padding(30)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.HM_BG)

      if (this.splashVisible) {
        SplashScreen({
          appName: this.splashAppName,
          onClose: this.closeSplash
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}