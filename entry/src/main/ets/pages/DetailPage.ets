/**
 * HPVPlayer - 详情页：背景图 + 海报 + 元数据 + 播放/集数列表。
 * 官方风格：NavDestination 标准标题栏 + 深浅色资源。
 */
import { fileUri } from '@kit.CoreFileKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { DetailParam, VideoItem } from '../models/Library';
import { LibraryStore } from '../services/LibraryStore';
import { ScrapeCandidate, Scraper } from '../services/Scraper';
import { appNav, NavRoutes, libraryDirty } from '../services/AppNav';
import { MediaTypes } from '../services/MediaTypes';

@ComponentV2
export struct DetailPage {
  @Local items: VideoItem[] = [];
  @Local param: DetailParam = { title: '', kind: 'movie', season: -1 };
  // 手动搜索
  @Local showSearch: boolean = false;
  @Local searchQuery: string = '';
  @Local searching: boolean = false;
  @Local searchError: string = '';
  @Local candidates: ScrapeCandidate[] = [];

  aboutToAppear(): void {
    const params = appNav.getParamByName(NavRoutes.DETAIL) as DetailParam[];
    if (params.length > 0) {
      this.param = params[params.length - 1];
    }
    this.items = LibraryStore.get().getGroupItems(this.param);
  }

  private reload(): void {
    // 匹配后 title 可能被 TMDB 规范名覆盖，用组内首个条目的当前 title 重新查询
    const store = LibraryStore.get();
    if (this.items.length > 0) {
      const currentTitle = this.items[0].title;
      if (currentTitle !== this.param.title) {
        this.param = {
          title: currentTitle,
          kind: this.param.kind,
          season: this.param.season,
        };
      }
    }
    this.items = store.getGroupItems(this.param);
  }

  private openSearch(): void {
    this.searchQuery = this.param.title;
    this.searchError = '';
    this.candidates = [];
    this.showSearch = true;
  }

  private async doSearch(): Promise<void> {
    const query = this.searchQuery.trim();
    if (query.length === 0) {
      this.searchError = '请输入关键词';
      return;
    }
    this.searching = true;
    this.searchError = '';
    this.candidates = [];
    try {
      const isTv = this.param.kind === 'episode';
      this.candidates = await Scraper.searchCandidates(query, isTv);
      if (this.candidates.length === 0) {
        this.searchError = '没有找到匹配结果';
      }
    } catch (err) {
      this.searchError = (err as Error).message;
    } finally {
      this.searching = false;
    }
  }

  private async applyCandidate(candidate: ScrapeCandidate): Promise<void> {
    try {
      await Scraper.applyCandidate(this.param, this.items, candidate);
      this.showSearch = false;
      this.reload();
      libraryDirty.emit(); // 通知首页海报墙刷新
      this.getUIContext().getPromptAction().showToast({ message: '已应用匹配结果' });
    } catch (err) {
      this.searchError = (err as Error).message;
    }
  }

  private get head(): VideoItem | null {
    return this.items.length > 0 ? this.items[0] : null;
  }

  private posterUri(item: VideoItem | null): string {
    if (item !== null && item.posterFile !== undefined && item.posterFile !== '') {
      return fileUri.getUriFromPath(item.posterFile);
    }
    return '';
  }

  private backdropUri(): string {
    for (const item of this.items) {
      if (item.backdropFile !== undefined && item.backdropFile !== '') {
        return fileUri.getUriFromPath(item.backdropFile);
      }
    }
    return '';
  }

  /** 展示标题：匹配后 title 已被 TMDB 规范名覆盖（reload 时同步 param） */
  private displayTitle(): string {
    return this.param.title;
  }

  private subtitle(): string {
    const head = this.head;
    if (head === null) {
      return '';
    }
    const parts: string[] = [];
    if (head.year !== undefined && head.year > 0) {
      parts.push(`${head.year}`);
    }
    if (head.releaseDate !== undefined && head.releaseDate.length >= 10) {
      parts.push(`上映 ${head.releaseDate.substring(0, 10)}`);
    }
    if (head.runtime !== undefined && head.runtime > 0) {
      const h = Math.floor(head.runtime / 60);
      const m = head.runtime % 60;
      parts.push(h > 0 ? `${h}小时${m > 0 ? `${m}分钟` : ''}` : `${m}分钟`);
    }
    if (head.rating !== undefined && head.rating > 0) {
      parts.push(`★ ${head.rating.toFixed(1)}`);
    }
    if (this.param.kind === 'episode') {
      parts.push(`第 ${this.param.season > 0 ? this.param.season : 1} 季 · ${this.items.length} 集`);
    } else if (this.items.length > 1) {
      parts.push(`${this.items.length} 个版本`);
    }
    return parts.join(' · ');
  }

  /** 技术标签：HDR/DV/分辨率/位深（从首个视频条目名/文件特征推断 + TMDB 元数据） */
  private techTags(): string[] {
    const tags: string[] = [];
    const head = this.head;
    if (head === null) {
      return tags;
    }
    // 分辨率：从文件名识别 2160p/1080p/720p
    const resMatch = this.items[0].name.match(/(2160p|1080[pi]|720[pi]|4k)/i);
    if (resMatch !== null) {
      const res = resMatch[1].toLowerCase();
      tags.push(res === '4k' ? '2160p' : res.replace('i', 'p'));
    }
    // HDR / DV
    const name = this.items[0].name;
    if (/(dolby[ .]?vision|\bdv\b|dovi)/i.test(name)) {
      tags.push('杜比视界');
    } else if (/(hdr10\+?|\bhdr\b)/i.test(name)) {
      tags.push(/hdr10\+/i.test(name) ? 'HDR10+' : 'HDR');
    }
    // 位深
    if (/(10bit|10-bit|\bhevc\b.*10|h265.*10)/i.test(name)) {
      tags.push('10bit');
    }
    return tags;
  }

  build() {
    NavDestination() {
      Scroll() {
        Column() {
          // 海报 + 标题区
          Row({ space: 14 }) {
            if (this.posterUri(this.head) !== '') {
              Image(this.posterUri(this.head))
                .width(104)
                .height(156)
                .objectFit(ImageFit.Cover)
                .borderRadius(12)
                .shadow({ radius: 12, color: $r('app.color.scrim') })
            }
            Column({ space: 6 }) {
              Text(this.displayTitle())
                .fontSize(22)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
                .maxLines(3)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (this.subtitle() !== '') {
                Text(this.subtitle())
                  .fontSize(14)
                  .fontColor($r('app.color.text_secondary'))
              }
              if (this.head !== null && this.head.genres !== undefined &&
                this.head.genres.length > 0) {
                Text(this.head.genres.join(' / '))
                  .fontSize(12)
                  .fontColor($r('app.color.brand'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              // 技术标签
              if (this.techTags().length > 0) {
                Row({ space: 6 }) {
                  ForEach(this.techTags(), (tag: string, idx: number) => {
                    Text(tag)
                      .fontSize(10)
                      .fontColor($r('app.color.brand'))
                      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                      .borderRadius(4)
                      .border({ width: 1, color: $r('app.color.brand_light') })
                  }, (tag: string, idx: number) => `${idx}-${tag}`)
                }
              }
              Text(MediaTypes.formatSize(this.items.reduce((sum: number, i: VideoItem) =>
                sum + i.size, 0)) || ' ')
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8 })

          // 播放按钮（电影：唯一入口，不列文件列表）
          Button(this.param.kind === 'episode' ?
            `播放第 1 集` : (this.items.length > 1 ? '播放首选版本' : '播放'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .height(44)
            .padding({ left: 40, right: 40 })
            .backgroundColor($r('app.color.brand'))
            .fontColor($r('app.color.text_on_brand'))
            .borderRadius(22)
            .margin({ top: 16, bottom: 8 })
            .onClick(() => LibraryStore.get().playGroup(this.param, 0))

          // 简介
          if (this.head !== null && this.head.overview !== undefined &&
            this.head.overview.length > 0) {
            Text(this.head.overview)
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .lineHeight(22)
              .width('100%')
              .padding({ left: 16, right: 16, top: 12 })
          } else {
            Text('暂无简介。可在设置中配置 TMDB API Key 后重新扫描以获取海报与简介。')
              .fontSize(13)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .padding({ left: 16, right: 16, top: 12 })
          }

          // 演员表
          if (this.head !== null && this.head.cast !== undefined && this.head.cast.length > 0) {
            Column({ space: 8 }) {
              Text('演员')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
              Scroll() {
                Row({ space: 8 }) {
                  ForEach(this.head.cast, (member: string, idx: number) => {
                    Text(member)
                      .fontSize(13)
                      .fontColor($r('app.color.text_secondary'))
                      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                      .borderRadius(16)
                      .backgroundColor($r('app.color.input_background'))
                  }, (member: string, idx: number) => `${idx}-${member}`)
                }
              }
              .scrollable(ScrollDirection.Horizontal)
              .scrollBar(BarState.Off)
              .width('100%')
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 16 })
          }

          // 集数列表（仅剧集；电影只有播放按钮不列文件）
          if (this.param.kind === 'episode') {
            Text('剧集')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
              .padding({ left: 16, right: 16, top: 20, bottom: 8 })

            Column() {
              ForEach(this.items, (item: VideoItem, idx: number) => {
                Column({ space: 2 }) {
                  Row({ space: 12 }) {
                    Column() {
                      Text(`${item.episode ?? idx + 1}`)
                        .fontSize(17)
                        .fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.brand'))
                      Text('集')
                        .fontSize(10)
                        .fontColor($r('app.color.text_secondary'))
                    }
                    .width(40)
                    Column({ space: 2 }) {
                      // 集标题（TMDB 匹配），无则显示文件名解析的标题
                      Text(item.episodeTitle !== undefined && item.episodeTitle.length > 0 ?
                        item.episodeTitle : `第 ${item.episode ?? idx + 1} 集`)
                        .fontSize(16)
                        .fontColor($r('app.color.text_primary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      // 文件名（小号灰色）
                      Text(item.name)
                        .fontSize(11)
                        .fontColor($r('app.color.text_tertiary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                    SymbolGlyph($r('sys.symbol.play_round_triangle'))
                      .fontSize(20)
                      .fontColor([$r('app.color.text_tertiary')])
                  }
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                }
                .width('100%')
                .borderRadius(16)
                .backgroundColor($r('app.color.card_background'))
                .margin({ bottom: 8 })
                .onClick(() => LibraryStore.get().playGroup(this.param, idx))
              }, (item: VideoItem) => item.id)
            }
            .padding({ left: 16, right: 16, bottom: 24 })
          } else {
            // 电影：底部留白
            Column().height(24)
          }
        }
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
      .width('100%')
      .height('100%')
    }
    .title(this.param.title)
    .menus(this.detailMenu())
    .backgroundColor($r('app.color.page_background'))
    .onShown(() => {
      // 从播放页/其它页面回来时刷新（标题、演员表等可能已更新）
      this.reload();
    })
    .bindSheet($$this.showSearch, this.searchSheetView(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: true,
      backgroundColor: $r('app.color.card_background'),
      title: { title: '手动匹配' },
    })
  }

  @Builder
  detailMenu() {
    Menu() {
      MenuItem({
        content: '手动搜索匹配',
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.magnifyingglass'))
          .fontColor([$r('app.color.brand')]),
      })
        .onClick(() => this.openSearch())
    }
  }

  @Builder
  candidateRow(candidate: ScrapeCandidate, index: number) {
    Row({ space: 12 }) {
      Text(candidate.title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (candidate.year > 0) {
        Text(`${candidate.year}`)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
      }
      if (candidate.rating > 0) {
        Text(`★ ${candidate.rating.toFixed(1)}`)
          .fontSize(13)
          .fontColor($r('app.color.brand'))
      }
      Text('匹配')
        .fontSize(13)
        .fontColor($r('app.color.brand'))
        .padding({ left: 10, right: 10 })
        .onClick(() => this.applyCandidate(candidate))
    }
    .width('100%')
    .padding(14)
    .borderRadius(12)
    .backgroundColor($r('app.color.input_background'))
    .margin({ bottom: 6 })
    .onClick(() => this.applyCandidate(candidate))
  }

  @Builder
  searchSheetView() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        TextInput({ text: this.searchQuery, placeholder: '影视名称（支持中文/英文）' })
          .height(48)
          .fontSize(16)
          .backgroundColor($r('app.color.input_background'))
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_tertiary'))
          .borderRadius(12)
          .layoutWeight(1)
          .onChange((v: string) => {
            this.searchQuery = v;
          })
          .onSubmit(() => this.doSearch())
        Button('搜索')
          .height(44)
          .fontSize(15)
          .backgroundColor($r('app.color.brand'))
          .fontColor($r('app.color.text_on_brand'))
          .borderRadius(22)
          .onClick(() => this.doSearch())
      }
      .width('100%')

      if (this.searching) {
        Column({ space: 8 }) {
          LoadingProgress().width(32).height(32).color($r('app.color.brand'))
          Text('搜索中…')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .padding({ top: 24 })
      } else if (this.searchError !== '') {
        Text(this.searchError)
          .fontSize(13)
          .fontColor($r('app.color.warning'))
          .width('100%')
          .padding({ top: 12, bottom: 12 })
      }

      Scroll() {
        Column() {
          ForEach(this.candidates, (candidate: ScrapeCandidate, idx: number) => {
            Column({ space: 4 }) {
              this.candidateRow(candidate, idx)
              if (candidate.overview.length > 0) {
                Text(candidate.overview)
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .padding({ left: 14, right: 14, bottom: 8 })
              }
            }
            .borderRadius(12)
            .backgroundColor($r('app.color.input_background'))
            .margin({ bottom: 6 })
          }, (candidate: ScrapeCandidate, idx: number) => `${candidate.tmdbId}-${idx}`)
        }
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 24 })
  }
}
