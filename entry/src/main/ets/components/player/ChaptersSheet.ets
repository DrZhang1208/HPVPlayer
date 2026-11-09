/**
 * HPVPlayer - 章节面板：章节列表跳转 + 上/下一章。
 */
import { Chapter, Player } from '@mpv-ohos/mpv-arkts';

function formatTime(seconds: number): string {
  if (seconds <= 0 || Number.isNaN(seconds)) {
    return '00:00';
  }
  const total = Math.floor(seconds);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const mm = m.toString().padStart(2, '0');
  const ss = s.toString().padStart(2, '0');
  return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
}

@ComponentV2
export struct ChaptersSheet {
  @Param @Require player: Player;

  build() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Button('上一章')
          .fontSize(14)
          .height(40)
          .backgroundColor($r('app.color.input_background'))
          .fontColor($r('app.color.text_secondary'))
          .borderRadius(20)
          .layoutWeight(1)
          .onClick(() => this.player.native.command(['chapter-prev']))
        Button('下一章')
          .fontSize(14)
          .height(40)
          .backgroundColor($r('app.color.input_background'))
          .fontColor($r('app.color.text_secondary'))
          .borderRadius(20)
          .layoutWeight(1)
          .onClick(() => this.player.native.command(['chapter-next']))
      }
      .width('100%')
      .padding({ top: 8 })

      if (this.player.state.chapters.length === 0) {
        Column() {
          Text('无章节信息')
            .fontSize(14)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        .padding(32)
        .alignItems(HorizontalAlign.Center)
      } else {
        Scroll() {
          Column() {
            ForEach(this.player.state.chapters, (chapter: Chapter, idx: number) => {
              Row({ space: 10 }) {
                Text(formatTime(chapter.time))
                  .fontSize(13)
                  .fontColor(this.isCurrent(idx) ?
                    $r('app.color.brand') : $r('app.color.text_secondary'))
                  .width(64)
                Text(chapter.title.length > 0 ? chapter.title : `章节 ${idx + 1}`)
                  .fontSize(16)
                  .fontColor(this.isCurrent(idx) ?
                    $r('app.color.brand') : $r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
              }
              .width('100%')
              .height(48)
              .borderRadius(12)
              .padding({ left: 8, right: 8 })
              .backgroundColor(this.isCurrent(idx) ?
                $r('app.color.brand_light') : Color.Transparent)
              .onClick(() => this.player.seek(chapter.time))
            }, (chapter: Chapter, idx: number) => `${idx}-${chapter.title}-${chapter.time}`)
          }
          .width('100%')
        }
        .scrollBar(BarState.Off)
        .align(Alignment.TopStart)
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, bottom: 24 })
  }

  private isCurrent(idx: number): boolean {
    const pos = this.player.state.position;
    const list = this.player.state.chapters;
    if (idx !== list.length - 1 && pos >= list[idx + 1].time) {
      return false;
    }
    return pos >= list[idx].time;
  }
}
