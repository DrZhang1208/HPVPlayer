/**
 * HPVPlayer - 播放列表面板：条目跳转 + 循环模式切换。
 */
import { Media, Player, PlaylistMode } from '@mpv-ohos/mpv-arkts';
import { PlayLauncher } from '../../services/PlayLauncher';

@ComponentV2
export struct PlaylistSheet {
  @Param @Require player: Player;

  build() {
    Column({ space: 8 }) {
      Text(`共 ${this.player.state.playlist.medias.length} 项`)
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 8 })

      // 循环模式
      Row({ space: 0 }) {
        this.modeChip('顺序', PlaylistMode.None)
        this.modeChip('单集', PlaylistMode.File)
        this.modeChip('列表', PlaylistMode.Playlist)
        this.modeChip('随机', PlaylistMode.Random)
      }
      .width('100%')
      .borderRadius(12)
      .backgroundColor($r('app.color.input_background'))

      Scroll() {
        Column() {
          ForEach(this.player.state.playlist.medias, (media: Media, idx: number) => {
            Row({ space: 10 }) {
              Text(idx === this.player.state.playlist.index ? '▶' : `${idx + 1}`)
                .fontSize(13)
                .fontColor(idx === this.player.state.playlist.index ?
                  $r('app.color.brand') : $r('app.color.text_secondary'))
                .width(28)
                .textAlign(TextAlign.Center)
              Text(PlayLauncher.baseName(media.uri))
                .fontSize(16)
                .fontColor(idx === this.player.state.playlist.index ?
                  $r('app.color.brand') : $r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .width('100%')
            .height(48)
            .borderRadius(12)
            .padding({ left: 4, right: 8 })
            .backgroundColor(idx === this.player.state.playlist.index ?
              $r('app.color.brand_light') : Color.Transparent)
            .onClick(() => this.player.jump(idx))
          }, (media: Media, idx: number) => `${idx}-${media.uri}`)
        }
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, bottom: 24 })
  }

  @Builder
  modeChip(label: string, mode: PlaylistMode) {
    Text(label)
      .fontSize(14)
      .fontColor(this.player.state.playlistMode === mode ?
        $r('app.color.brand') : $r('app.color.text_secondary'))
      .textAlign(TextAlign.Center)
      .height(40)
      .layoutWeight(1)
      .borderRadius(12)
      .backgroundColor(this.player.state.playlistMode === mode ?
        $r('app.color.brand_light') : Color.Transparent)
      .onClick(() => this.player.setPlaylistMode(mode))
  }
}
