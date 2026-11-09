/**
 * HPVPlayer - 详情页：背景图 + 海报 + 元数据 + 播放/集数列表。
 * 官方风格：NavDestination 标准标题栏 + 深浅色资源。
 */
import { fileUri } from '@kit.CoreFileKit';
import { DetailParam, VideoItem } from '../models/Library';
import { LibraryStore } from '../services/LibraryStore';
import { appNav, NavRoutes } from '../services/AppNav';
import { MediaTypes } from '../services/MediaTypes';

@ComponentV2
export struct DetailPage {
  @Local items: VideoItem[] = [];
  @Local param: DetailParam = { title: '', kind: 'movie', season: -1 };

  aboutToAppear(): void {
    const params = appNav.getParamByName(NavRoutes.DETAIL) as DetailParam[];
    if (params.length > 0) {
      this.param = params[params.length - 1];
    }
    this.items = LibraryStore.get().getGroupItems(this.param);
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

  private subtitle(): string {
    const head = this.head;
    if (head === null) {
      return '';
    }
    const parts: string[] = [];
    if (head.year !== undefined && head.year > 0) {
      parts.push(`${head.year}`);
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
              Text(this.param.title)
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

          // 播放按钮
          Button(this.param.kind === 'episode' ? '播放第 1 集' : '播放')
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

          // 文件/集数列表
          Text(this.param.kind === 'episode' ? '剧集' : '文件')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 20, bottom: 8 })

          Column() {
            ForEach(this.items, (item: VideoItem, idx: number) => {
              Row({ space: 12 }) {
                if (this.param.kind === 'episode') {
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
                } else {
                  SymbolGlyph($r('sys.symbol.film'))
                    .fontSize(20)
                    .fontColor([$r('app.color.text_secondary')])
                    .width(40)
                }
                Column({ space: 2 }) {
                  Text(item.name)
                    .fontSize(16)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(item.size > 0 ? MediaTypes.formatSize(item.size) : ' ')
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                SymbolGlyph($r('sys.symbol.play_round_triangle'))
                  .fontSize(20)
                  .fontColor([$r('app.color.text_tertiary')])
              }
              .width('100%')
              .height(56)
              .padding({ left: 16, right: 16 })
              .borderRadius(16)
              .backgroundColor($r('app.color.card_background'))
              .margin({ bottom: 8 })
              .onClick(() => LibraryStore.get().playGroup(this.param, idx))
            }, (item: VideoItem) => item.id)
          }
          .padding({ left: 16, right: 16, bottom: 24 })
        }
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
      .width('100%')
      .height('100%')
    }
    .title(this.param.title)
    .backgroundColor($r('app.color.page_background'))
  }
}
