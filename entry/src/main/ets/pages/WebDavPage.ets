/**
 * HPVPlayer - WebDAV 目录浏览（来源卡"浏览"进入）。
 * 服务器管理见 SourcesPage。
 * 官方风格：NavDestination 标准标题栏 + 深浅色资源。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { DavEntry, WebDavClient } from '../services/WebDavClient';
import { DavServer } from '../services/SettingsStore';
import { LibraryStore } from '../services/LibraryStore';
import { PlaylistItem, PlaylistParser } from '../services/PlaylistParser';
import { MediaTypes } from '../services/MediaTypes';
import { PlayItem } from '../models/PlayItem';
import { PlayLauncher } from '../services/PlayLauncher';
import { appNav, NavRoutes, WebDavBrowseParam } from '../services/AppNav';

const DOMAIN = 0x0000;

@ObservedV2
class DavPage {
  url: string;
  name: string;
  @Trace entries: DavEntry[] = [];
  @Trace loading: boolean = true;
  @Trace error: string = '';

  constructor(url: string, name: string) {
    this.url = url;
    this.name = name;
  }
}

@ComponentV2
export struct WebDavPage {
  @Local pages: DavPage[] = [];
  @Local refreshingDir: boolean = false;
  @Local missing: boolean = false;

  private server: DavServer | null = null;

  aboutToAppear(): void {
    const params = appNav.getParamByName(NavRoutes.WEBDAV) as WebDavBrowseParam[];
    const sourceId = params.length > 0 ? (params[params.length - 1].sourceId ?? '') : '';
    const source = LibraryStore.get().getSource(sourceId);
    if (source === null || source.type !== 'webdav' || (source.url ?? '') === '') {
      this.missing = true;
      return;
    }
    this.server = LibraryStore.sourceToDavServer(source);
    this.pages = [new DavPage(this.server.url, source.name)];
    this.loadDir(this.pages[0]);
  }

  private get current(): DavPage | null {
    return this.pages.length > 0 ? this.pages[this.pages.length - 1] : null;
  }

  private goBack(): void {
    this.pages.pop();
    if (this.pages.length === 0) {
      appNav.pop();
    }
  }

  private loadDir(page: DavPage): void {
    const server = this.server;
    if (server === null) {
      return;
    }
    page.loading = true;
    page.error = '';
    WebDavClient.propfind(server, page.url).then((entries: DavEntry[]) => {
      page.entries = entries;
      page.loading = false;
      this.refreshingDir = false;
    }).catch((err: BusinessError) => {
      hilog.error(DOMAIN, 'HPVPlayer', 'propfind failed: %{public}s', JSON.stringify(err));
      page.error = err.message ?? JSON.stringify(err);
      page.loading = false;
      this.refreshingDir = false;
    });
  }

  private enterDir(entry: DavEntry): void {
    const current = this.current;
    if (current === null || this.server === null) {
      return;
    }
    const page = new DavPage(WebDavClient.joinUrl(current.url, entry.name, true), entry.name);
    this.pages.push(page);
    this.loadDir(page);
  }

  private toPlayItem(url: string, title: string): PlayItem {
    const server = this.server!;
    const extra: Record<string, string> = {};
    WebDavClient.extraOptions(server).forEach((value: string, key: string) => {
      extra[key] = value;
    });
    const item: PlayItem = {
      uri: url,
      title: title,
      headers: WebDavClient.authHeaders(server),
    };
    if (Object.keys(extra).length > 0) {
      item.extraOptions = extra;
    }
    return item;
  }

  private playAll(): void {
    const current = this.current;
    if (current === null) {
      return;
    }
    const items = current.entries
      .filter((e: DavEntry) => !e.isDir && MediaTypes.isMedia(e.name))
      .map((e: DavEntry) => this.toPlayItem(WebDavClient.joinUrl(current.url, e.name, false), e.name));
    if (items.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '本目录没有可播放的媒体文件' });
      return;
    }
    PlayLauncher.play(items, 0, 'webdav');
  }

  private async playPlaylist(entry: DavEntry): Promise<void> {
    const current = this.current;
    const server = this.server;
    if (current === null || server === null) {
      return;
    }
    const url = WebDavClient.joinUrl(current.url, entry.name, false);
    try {
      this.getUIContext().getPromptAction().showToast({ message: '正在获取播放列表…' });
      const text = await WebDavClient.getText(server, url);
      const parsed = PlaylistParser.parseM3U(text, url);
      if (parsed.length === 0) {
        this.getUIContext().getPromptAction().showToast({ message: '播放列表为空' });
        return;
      }
      const items = parsed.map((p: PlaylistItem) =>
        this.toPlayItem(p.url, p.title.length > 0 ? p.title : PlayLauncher.baseName(p.url)));
      PlayLauncher.play(items, 0, 'webdav');
    } catch (err) {
      hilog.error(DOMAIN, 'HPVPlayer', 'load m3u failed: %{public}s', JSON.stringify(err));
      this.getUIContext().getPromptAction().showToast({ message: '播放列表获取失败' });
    }
  }

  private onEntryTap(entry: DavEntry): void {
    if (entry.isDir) {
      this.enterDir(entry);
      return;
    }
    const current = this.current;
    if (current === null) {
      return;
    }
    if (MediaTypes.isPlaylist(entry.name)) {
      this.playPlaylist(entry);
      return;
    }
    if (MediaTypes.isMedia(entry.name)) {
      PlayLauncher.play([this.toPlayItem(WebDavClient.joinUrl(current.url, entry.name, false),
        entry.name)], 0, 'webdav');
      return;
    }
    this.getUIContext().getPromptAction().showToast({ message: '不支持的文件类型' });
  }

  private entryIcon(entry: DavEntry): Resource {
    if (entry.isDir) {
      return $r('sys.symbol.folder_fill');
    }
    if (MediaTypes.isPlaylist(entry.name)) {
      return $r('sys.symbol.doc_plaintext');
    }
    if (MediaTypes.isVideo(entry.name)) {
      return $r('sys.symbol.video_fill');
    }
    if (MediaTypes.isAudio(entry.name)) {
      return $r('sys.symbol.music');
    }
    return $r('sys.symbol.doc_text');
  }

  @Builder
  davEntryRow(entry: DavEntry) {
    Row({ space: 12 }) {
      SymbolGlyph(this.entryIcon(entry))
        .fontSize(22)
        .fontColor([entry.isDir ? $r('app.color.brand') : $r('app.color.text_secondary')])
        .width(28)
      Column({ space: 2 }) {
        Text(entry.name)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (!entry.isDir && entry.size > 0) {
          Text(MediaTypes.formatSize(entry.size))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 16 })
    .borderRadius(16)
    .margin({ bottom: 4 })
    .backgroundColor($r('app.color.card_background'))
    .onClick(() => this.onEntryTap(entry))
  }

  @Builder
  pageMenu() {
    Menu() {
      MenuItem({
        content: '播放全部',
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.play_fill'))
          .fontColor([$r('app.color.brand')]),
      })
        .onClick(() => this.playAll())
      MenuItem({
        content: '刷新',
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.arrow_clockwise'))
          .fontColor([$r('app.color.brand')]),
      })
        .onClick(() => {
          const page = this.current;
          if (page !== null) {
            this.loadDir(page);
          }
        })
    }
  }

  build() {
    NavDestination() {
      if (this.missing) {
        Column({ space: 10 }) {
          Text('来源不存在或类型错误')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.current !== null && this.current.loading) {
        Column({ space: 12 }) {
          LoadingProgress().width(40).height(40).color($r('app.color.brand'))
          Text('加载中…')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.current !== null && this.current.error !== '') {
        Column({ space: 12 }) {
          Text(this.current.error)
            .fontSize(14)
            .fontColor($r('app.color.warning'))
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })
          Button('重试')
            .height(40)
            .fontSize(16)
            .backgroundColor($r('app.color.brand'))
            .fontColor($r('app.color.text_on_brand'))
            .borderRadius(20)
            .onClick(() => {
              const page = this.current;
              if (page !== null) {
                this.loadDir(page);
              }
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Refresh({ refreshing: $$this.refreshingDir }) {
          Scroll() {
            Column() {
              ForEach(this.current?.entries ?? [], (entry: DavEntry) => {
                this.davEntryRow(entry)
              }, (entry: DavEntry) => `${entry.name}-${entry.isDir}`)
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 4, bottom: 24 })
          }
          .scrollBar(BarState.Off)
        }
        .onRefreshing(() => {
          const page = this.current;
          if (page !== null) {
            this.loadDir(page);
          } else {
            this.refreshingDir = false;
          }
        })
        .layoutWeight(1)
      }
    }
    .onBackPressed(() => {
      // 子目录逐级返回，根目录交回系统返回
      if (this.pages.length > 1) {
        this.pages.pop();
        return true;
      }
      return false;
    })
    .title(this.current?.name ?? 'WebDAV')
    .menus(this.pageMenu())
    .backgroundColor($r('app.color.page_background'))
  }
}
