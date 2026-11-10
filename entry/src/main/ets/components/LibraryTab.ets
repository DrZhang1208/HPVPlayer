/**
 * HPVPlayer - 媒体库 Tab：海报墙 / 分类浏览 / 扫描与刮削进度 / URL 快速播放。
 * 由 Index（Tabs 容器）内嵌。
 */
import { common } from '@kit.AbilityKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { picker } from '@kit.CoreFileKit';
import { fileUri } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DetailParam, LibraryGroup, MediaSource } from '../models/Library';
import { PlayItem } from '../models/PlayItem';
import { PlayLauncher } from '../services/PlayLauncher';
import { LibraryStore } from '../services/LibraryStore';
import { LibraryOps, LibraryProgress } from '../services/LibraryOps';
import { SettingsStore } from '../services/SettingsStore';
import { Scraper } from '../services/Scraper';
import { TmdbClient } from '../services/TmdbClient';
import { BangumiClient } from '../services/BangumiClient';
import { appNav, NavRoutes, tabSignal, TabIndex, libraryDirty } from '../services/AppNav';

const DOMAIN = 0x0000;

const MEDIA_SUFFIXES: string[] = [
  '.mp4', '.mkv', '.avi', '.mov', '.flv', '.ts', '.m2ts', '.webm', '.wmv',
  '.mpg', '.mpeg', '.3gp', '.rm', '.rmvb', '.m4v', '.vob', '.ogv', '.iso',
  '.mp3', '.flac', '.wav', '.aac', '.ogg', '.opus', '.m4a', '.ape',
  '.m3u', '.m3u8',
];

type ChipFilter = 'all' | 'movie' | 'episode' | 'unknown' | 'recent';

interface ChipDef {
  f: ChipFilter;
  label: string;
}

const CHIPS: ChipDef[] = [
  { f: 'all', label: '全部' },
  { f: 'movie', label: '电影' },
  { f: 'episode', label: '剧集' },
  { f: 'recent', label: '最近添加' },
  { f: 'unknown', label: '未识别' },
];

const PLACEHOLDER_RES: Resource[] = [
  $r('app.color.placeholder_bg_1'),
  $r('app.color.placeholder_bg_2'),
  $r('app.color.placeholder_bg_3'),
  $r('app.color.placeholder_bg_4'),
  $r('app.color.placeholder_bg_5'),
];

function placeholderRes(title: string): Resource {
  let hash = 0;
  for (let i = 0; i < title.length; i++) {
    hash = (hash * 31 + title.charCodeAt(i)) % 997;
  }
  return PLACEHOLDER_RES[hash % PLACEHOLDER_RES.length];
}

@ComponentV2
export struct LibraryTab {
  @Local groups: LibraryGroup[] = [];
  @Local filter: ChipFilter = 'all';
  @Local busy: boolean = false;
  @Local busyText: string = '';
  @Local showUrlSheet: boolean = false;
  @Local urlInput: string = '';
  // 海报墙列数按可用宽度自适应，避免横屏/大屏下卡片过大一行仅 3 列
  @Local gridCols: number = 3;
  private inited: boolean = false;
  private dirtyHooked: boolean = false;

  private columnsTemplate(): string {
    return `1fr `.repeat(this.gridCols).trim();
  }

  /** 卡片标题字号：列数越多卡片越小，字号随之缩小（14→12） */
  private titleFontSize(): number {
    return this.gridCols >= 8 ? 12 : (this.gridCols >= 5 ? 13 : 14);
  }

  /** 占位首字母字号 */
  private placeholderFontSize(): number {
    return this.gridCols >= 8 ? 22 : (this.gridCols >= 5 ? 26 : 30);
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  aboutToAppear(): void {
    if (!this.dirtyHooked) {
      this.dirtyHooked = true;
      libraryDirty.on(() => {
        this.refreshGroups();
      });
    }
    if (this.inited) {
      this.refreshGroups();
      return;
    }
    this.inited = true;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    SettingsStore.init(context).then(async () => {
      await LibraryStore.get().init(context);
      TmdbClient.init(context);
      BangumiClient.init(context);
      this.consumeDebugSource();
      this.refreshGroups();
      // 首次进入自动扫描 + 刮削
      LibraryOps.autoScanOnce((p: LibraryProgress) => {
        this.busy = true;
        this.busyText = p.phase === 'scan' ?
          `扫描中 · ${p.current}` : `刮削 ${p.done}/${p.total} · ${p.current}`;
      }).then(() => {
        this.busy = false;
        this.busyText = '';
        this.refreshGroups();
      });
    });
  }

  /** 消费调试入口传入的来源（Want 参数 → AppStorage） */
  private consumeDebugSource(): void {
    const raw = AppStorage.get<string>('hpvAddSource');
    if (raw === undefined || raw.length === 0) {
      return;
    }
    AppStorage.delete('hpvAddSource');
    try {
      const source = JSON.parse(raw) as MediaSource;
      const store = LibraryStore.get();
      if (source.id !== undefined && source.id.length > 0 &&
        store.getSource(source.id) === null) {
        store.addSource(source);
        hilog.info(DOMAIN, 'HPVPlayer', 'debug source added: %{public}s', source.id);
      }
    } catch (err) {
      hilog.warn(DOMAIN, 'HPVPlayer', 'debug source parse failed: %{public}s',
        JSON.stringify(err));
    }
  }

  private refreshGroups(): void {
    this.groups = LibraryStore.get().getGroups(this.filter);
  }

  private changeFilter(f: ChipFilter): void {
    this.filter = f;
    this.refreshGroups();
  }

  private openDetail(group: LibraryGroup): void {
    const param: DetailParam = { title: group.title, kind: group.kind, season: group.season };
    appNav.pushPath({ name: NavRoutes.DETAIL, param: param });
  }

  private playUrl(): void {
    const url = this.urlInput.trim();
    if (url.length === 0) {
      this.toast('请输入视频地址');
      return;
    }
    this.showUrlSheet = false;
    const item: PlayItem = { uri: url, title: PlayLauncher.baseName(url) };
    PlayLauncher.play([item], 0, 'url');
  }

  private async pickLocalQuick(): Promise<void> {
    try {
      const docPicker = new picker.DocumentViewPicker();
      const result: string[] = await docPicker.select({
        fileSuffixFilters: MEDIA_SUFFIXES,
        maxSelectNumber: 500,
      });
      if (result.length === 0) {
        return;
      }
      const items: PlayItem[] = [];
      for (const uri of result) {
        const item: PlayItem = { uri: uri, title: PlayLauncher.baseName(uri) };
        items.push(item);
      }
      PlayLauncher.play(items, 0, 'local');
    } catch (err) {
      hilog.error(DOMAIN, 'HPVPlayer', 'quick pick failed: %{public}s', JSON.stringify(err));
    }
  }

  private async rescanAll(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.busyText = '正在扫描…';
    try {
      await LibraryOps.scanAll((p: LibraryProgress) => {
        this.busyText = p.phase === 'scan' ?
          `扫描中 · ${p.current}` : `刮削 ${p.done}/${p.total} · ${p.current}`;
      });
    } finally {
      this.busy = false;
      this.busyText = '';
      this.refreshGroups();
    }
  }

  private async rescrapeAll(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.busyText = '重新刮削…';
    try {
      const matched = await Scraper.rescrapeAll((p) => {
        this.busyText = `刮削 ${p.done}/${p.total} · ${p.current}`;
      });
      this.toast(`刮削完成，匹配 ${matched} 组`);
    } catch (err) {
      this.toast(`${(err as Error).message}`);
    } finally {
      this.busy = false;
      this.busyText = '';
      this.refreshGroups();
    }
  }

  @Builder
  chip(f: ChipFilter, label: string) {
    Text(label)
      .fontSize(14)
      .fontColor(this.filter === f ? $r('app.color.brand') : $r('app.color.text_secondary'))
      .height(32)
      .padding({ left: 14, right: 14 })
      .borderRadius(16)
      .backgroundColor(this.filter === f ? $r('app.color.chip_background') :
        $r('app.color.input_background'))
      .onClick(() => this.changeFilter(f))
  }

  @Builder
  posterCell(group: LibraryGroup) {
    Column({ space: 6 }) {
      Stack() {
        if (group.posterFile !== '') {
          Image(fileUri.getUriFromPath(group.posterFile))
            .width('100%')
            .aspectRatio(0.67)
            .objectFit(ImageFit.Cover)
            .borderRadius(12)
        } else {
          Column({ space: 8 }) {
            Text(group.title.length > 0 ? group.title.substring(0, 1) : '?')
              .fontSize(this.placeholderFontSize())
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_secondary'))
            if (group.kind === 'episode') {
              Text(`S${group.season > 0 ? group.season : 1}`)
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
            }
          }
          .width('100%')
          .aspectRatio(0.67)
          .borderRadius(12)
          .backgroundColor(placeholderRes(group.title))
          .justifyContent(FlexAlign.Center)
        }
        if (group.kind === 'episode') {
          Text(`共${group.items.length}集`)
            .fontSize(this.gridCols >= 6 ? 9 : 10)
            .fontColor(Color.White)
            .backgroundColor($r('app.color.player_control_bg'))
            .borderRadius(6)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .position({ x: 8, y: 8 })
        }
      }
      .width('100%')

      Text(group.title)
        .fontSize(this.titleFontSize())
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text(group.year > 0 ? `${group.year}` : ' ')
        .fontSize(this.gridCols >= 8 ? 10 : 12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .onClick(() => this.openDetail(group))
  }

  @Builder
  urlSheetView() {
    Column({ space: 12 }) {
      Text('打开 URL')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 4 })
      TextInput({ text: this.urlInput, placeholder: '视频/直播地址（http/https）' })
        .height(48)
        .fontSize(16)
        .backgroundColor($r('app.color.input_background'))
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_tertiary'))
        .borderRadius(12)
        .onChange((v: string) => {
          this.urlInput = v;
        })
        .onSubmit(() => this.playUrl())
      Button('播放')
        .height(44)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .backgroundColor($r('app.color.brand'))
        .fontColor($r('app.color.text_on_brand'))
        .borderRadius(22)
        .onClick(() => this.playUrl())
    }
    .width('100%')
    .padding({ left: 20, right: 20, bottom: 28 })
  }

  @Builder
  pageMenu() {
    Menu() {
      MenuItem({
        content: '刷新（重新扫描）',
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.arrow_clockwise'))
          .fontColor([$r('app.color.brand')]),
      })
        .onClick(() => this.rescanAll())
      MenuItem({
        content: '重新刮削全部',
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.wand_and_stars'))
          .fontColor([$r('app.color.brand')]),
      })
        .onClick(() => this.rescrapeAll())
      MenuItem({
        content: '打开 URL',
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.paperplane'))
          .fontColor([$r('app.color.brand')]),
      })
        .onClick(() => {
          this.showUrlSheet = true;
        })
      MenuItem({
        content: '播放本地文件',
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.video_fill'))
          .fontColor([$r('app.color.brand')]),
      })
        .onClick(() => this.pickLocalQuick())
    }
  }

  build() {
    Column() {
      // 分类
      Scroll() {
        Row({ space: 8 }) {
          ForEach(CHIPS, (c: ChipDef) => {
            this.chip(c.f, c.label)
          }, (c: ChipDef) => `${c.f}`)
        }
        .padding({ left: 16, right: 16, top: 4, bottom: 8 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')

      // 扫描/刮削进度
      if (this.busy) {
        Row({ space: 8 }) {
          LoadingProgress().width(16).height(16).color($r('app.color.brand'))
          Text(this.busyText)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })
      }

      // 海报墙 / 空态
      if (this.groups.length > 0) {
        Grid() {
          ForEach(this.groups, (group: LibraryGroup) => {
            GridItem() {
              this.posterCell(group)
            }
          }, (group: LibraryGroup) => `${group.title}-${group.posterFile !== ''}`)
        }
        .columnsTemplate(this.columnsTemplate())
        .columnsGap(this.gridCols >= 6 ? 10 : 12)
        .rowsGap(this.gridCols >= 6 ? 12 : 16)
        .padding({ left: 16, right: 16, top: 4, bottom: 24 })
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .onAreaChange((_old: Area, newArea: Area) => {
          // 按官方断点 sm(<600vp)/md(<840vp)/lg(>=840vp) 自适应列数：
          // 手机 3 列起、折叠/小平板 4 列起、平板横屏 6 列起，目标卡片宽约 110~150vp
          const width = newArea.width as number;
          if (width > 0) {
            let target = 112;
            let minCols = 3;
            if (width >= 840) {
              target = 150;
              minCols = 6;
            } else if (width >= 600) {
              target = 140;
              minCols = 4;
            }
            this.gridCols = Math.max(minCols, Math.min(12, Math.floor(width / target)));
          }
        })
      } else {
        this.emptyView()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .bindSheet($$this.showUrlSheet, this.urlSheetView(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: true,
      backgroundColor: $r('app.color.card_background'),
    })
  }

  @Builder
  emptyView() {
    Column({ space: 12 }) {
      if (LibraryStore.get().sources.length === 0) {
        SymbolGlyph($r('sys.symbol.rectangle_stack'))
          .fontSize(44)
          .fontColor([$r('app.color.text_tertiary')])
        Text('媒体库是空的')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text('在「资源库」中添加本地文件夹或 WebDAV 服务器作为来源，\n视频将自动扫描入库并匹配海报与简介。')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
        Button('去资源库添加')
          .height(44)
          .fontSize(16)
          .backgroundColor($r('app.color.brand'))
          .fontColor($r('app.color.text_on_brand'))
          .borderRadius(22)
          .padding({ left: 28, right: 28 })
          .margin({ top: 8 })
          .onClick(() => tabSignal.emit(TabIndex.SOURCES))
      } else {
        LoadingProgress().width(36).height(36).color($r('app.color.brand'))
        Text(this.busy ? '正在扫描媒体库…' : '此分类暂无内容')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }
}
