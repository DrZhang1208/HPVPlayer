/**
 * HPVPlayer - 视频信息面板：播放状态、轨道、参数、码率的实时只读展示。
 * 数据全部来自 PlayerState(@ObservedV2)，随属性变化自动刷新。
 */
import { Player } from '@mpv-ohos/mpv-arkts';

@ComponentV2
export struct StatusSheet {
  @Param @Require player: Player;

  private fmtBitrate(v: number): string {
    if (!Number.isFinite(v) || v <= 0) {
      return '-';
    }
    return `${(v / 1000000).toFixed(2)} Mbps`;
  }

  private fmtHz(v: number): string {
    if (!Number.isFinite(v) || v <= 0) {
      return '-';
    }
    return v >= 1000 ? `${(v / 1000).toFixed(1)} kHz` : `${v} Hz`;
  }

  private trackInfo(codec: string, lang: string, title: string): string {
    const parts: string[] = [];
    if (codec.length > 0) {
      parts.push(codec);
    }
    if (lang.length > 0) {
      parts.push(lang);
    }
    if (title.length > 0) {
      parts.push(title);
    }
    return parts.length > 0 ? parts.join(' · ') : '-';
  }

  private videoSizeText(): string {
    const p = this.player.state.videoParams;
    if (p.dw > 0 && p.dh > 0) {
      const suffix = (p.dw !== p.w || p.dh !== p.h) ? `（原始 ${p.w}×${p.h}）` : '';
      return `${p.dw}×${p.dh}${suffix}`;
    }
    return '-';
  }

  private colorText(): string {
    const p = this.player.state.videoParams;
    const parts: string[] = [];
    if (p.pixelFormat.length > 0) {
      parts.push(p.pixelFormat);
    }
    if (p.primaries.length > 0) {
      parts.push(p.primaries);
    }
    if (p.gamma.length > 0) {
      parts.push(p.gamma);
    }
    return parts.length > 0 ? parts.join(' · ') : '-';
  }

  private playStateText(): string {
    const s = this.player.state;
    if (s.buffering) {
      return `缓冲中 ${Math.round(s.bufferingPercentage)}%`;
    }
    return s.playing ? '播放中' : '已暂停';
  }

  @Builder
  infoRow(label: string, value: string) {
    Row({ space: 10 }) {
      Text(label)
        .fontSize(13)
        .fontColor($r('app.color.text_tertiary'))
        .width(76)
      Text(value)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 7, bottom: 7 })
  }

  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(14)
      .fontColor($r('app.color.text_secondary'))
      .margin({ top: 14, bottom: 4 })
  }

  build() {
    Scroll() {
      Column() {
        this.sectionTitle('播放')
        this.infoRow('状态', this.playStateText())
        this.infoRow('倍速', `${this.player.state.speed}x`)
        this.infoRow('缓冲', this.player.state.buffer > 0 ?
          `${Math.round(this.player.state.buffer)} 秒` : '-')

        this.sectionTitle('视频')
        this.infoRow('分辨率', this.videoSizeText())
        this.infoRow('色彩', this.colorText())
        this.infoRow('视频轨', this.trackInfo(this.player.state.track.video.codec,
          this.player.state.track.video.lang, this.player.state.track.video.title))
        this.infoRow('视频码率', this.fmtBitrate(this.player.state.videoBitrate))
        if (this.player.state.videoParams.rotate !== 0) {
          this.infoRow('旋转', `${this.player.state.videoParams.rotate}°`)
        }

        this.sectionTitle('音频')
        this.infoRow('音轨', this.trackInfo(this.player.state.track.audio.codec,
          this.player.state.track.audio.lang, this.player.state.track.audio.title))
        this.infoRow('格式', this.player.state.audioParams.format.length > 0 ?
          `${this.player.state.audioParams.format} · ${this.player.state.audioParams.channels}` : '-')
        this.infoRow('采样率', this.fmtHz(this.player.state.audioParams.sampleRate))
        this.infoRow('音频码率', this.fmtBitrate(this.player.state.audioBitrate))

        this.sectionTitle('字幕')
        this.infoRow('当前字幕', this.player.state.track.subs.id === 'no' ? '已关闭' :
          this.trackInfo(this.player.state.track.subs.codec,
            this.player.state.track.subs.lang, this.player.state.track.subs.title))
      }
      .constraintSize({ minHeight: '100%' })
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: 4, bottom: 24 })
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
    .align(Alignment.TopStart)
  }
}
