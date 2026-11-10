/**
 * HPVPlayer - 轨道选择面板：视频/音频/字幕 + 外挂字幕、外挂音轨加载。
 */
import { picker } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  AudioTrack, Player, SubtitleTrack, Utils, VideoTrack
} from '@mpv-ohos/mpv-arkts';
import { SUBTITLE_EXTS } from '../../services/MediaTypes';

const AUDIO_EXTS = ['.aac', '.flac', '.m4a', '.mp3', '.ogg', '.opus', '.wav', '.ape'];

@ComponentV2
export struct TracksSheet {
  @Param @Require player: Player;
  /** 打开时聚焦的分组：'audio' 只显音轨 / 'subs' 只显字幕 / 其余显示全部 */
  @Param focus: string = '';
  @Local loading: boolean = false;

  private showVideo(): boolean {
    return this.focus !== 'audio' && this.focus !== 'subs';
  }

  private showAudio(): boolean {
    return this.focus !== 'subs';
  }

  private showSubs(): boolean {
    return this.focus !== 'audio';
  }

  build() {
    Scroll() {
      Column({ space: 4 }) {
        if (this.showVideo()) {
          this.sectionTitle('视频轨')
          this.trackRow(this.player.state.track.video.id === 'auto', '自动', () => {
            this.player.setVideoTrack(VideoTrack.auto());
          })
          this.trackRow(this.player.state.track.video.id === 'no', '禁用视频', () => {
            this.player.disableVideoTrack();
          })
          ForEach(this.player.state.tracks.video, (t: VideoTrack) => {
            this.trackRow(this.player.state.track.video.id === t.id, this.trackLabel(t.title, t.lang, t.codec), () => {
              this.player.setVideoTrack(t);
            })
          }, (t: VideoTrack) => `v-${t.id}`)
        }

        if (this.showAudio()) {
          this.sectionTitle('音轨')
          this.trackRow(this.player.state.track.audio.id === 'auto', '自动', () => {
            this.player.setAudioTrack(AudioTrack.auto());
          })
          this.trackRow(this.player.state.track.audio.id === 'no', '静音', () => {
            this.player.disableAudioTrack();
          })
          ForEach(this.player.state.tracks.audio, (t: AudioTrack) => {
            this.trackRow(this.player.state.track.audio.id === t.id, this.trackLabel(t.title, t.lang, t.codec), () => {
              this.player.setAudioTrack(t);
            })
          }, (t: AudioTrack) => `a-${t.id}`)
        }

        if (this.showSubs()) {
          this.sectionTitle('字幕')
          this.trackRow(this.player.state.track.subs.id === 'auto', '自动', () => {
            this.player.setSubtitleTrack(SubtitleTrack.auto());
          })
          this.trackRow(this.player.state.track.subs.id === 'no', '关闭字幕', () => {
            this.player.disableSubtitleTrack();
          })
          ForEach(this.player.state.tracks.subs, (t: SubtitleTrack) => {
            this.trackRow(this.player.state.track.subs.id === t.id, this.trackLabel(t.title, t.lang, t.codec), () => {
              this.player.setSubtitleTrack(t);
            })
          }, (t: SubtitleTrack) => `s-${t.id}`)
        }

        this.sectionTitle('外挂轨道')
        if (this.showSubs()) {
          this.actionRow('加载外挂字幕（srt/ass/vtt…）', () => this.pickExternal(true))
        }
        if (this.showAudio()) {
          this.actionRow('加载外挂音轨（aac/flac/mp3…）', () => this.pickExternal(false))
        }
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

  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(14)
      .fontColor($r('app.color.text_secondary'))
      .margin({ top: 14, bottom: 4 })
  }

  @Builder
  trackRow(selected: boolean, label: string, onTap: () => void) {
    Row({ space: 8 }) {
      Text(selected ? '●' : '○')
        .fontSize(14)
        .fontColor(selected ? $r('app.color.brand') : $r('app.color.text_tertiary'))
      Text(label)
        .fontSize(16)
        .fontColor(selected ? $r('app.color.brand') : $r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .height(48)
    .borderRadius(12)
    .padding({ left: 8, right: 8 })
    .backgroundColor(selected ? $r('app.color.brand_light') : Color.Transparent)
    .onClick(() => onTap())
  }

  @Builder
  actionRow(label: string, onTap: () => void) {
    Row({ space: 8 }) {
      Text('＋').fontSize(16).fontColor($r('app.color.brand'))
      Text(label).fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
    }
    .width('100%')
    .height(48)
    .borderRadius(12)
    .padding({ left: 8, right: 8 })
    .backgroundColor($r('app.color.input_background'))
    .margin({ top: 4 })
    .onClick(() => onTap())
  }

  private trackLabel(title: string, lang: string, codec: string): string {
    let label = title.length > 0 ? title : '轨道';
    if (lang.length > 0) {
      label += ` · ${lang}`;
    }
    if (codec.length > 0) {
      label += ` · ${codec}`;
    }
    return label;
  }

  private async pickExternal(isSubtitle: boolean): Promise<void> {
    if (this.loading) {
      return;
    }
    try {
      const docPicker = new picker.DocumentViewPicker();
      const suffixes = isSubtitle ?
        SUBTITLE_EXTS.map((e: string) => `.${e}`) : AUDIO_EXTS;
      const result: string[] = await docPicker.select({
        fileSuffixFilters: suffixes,
        maxSelectNumber: 1,
      });
      if (result.length === 0) {
        return;
      }
      const uri = Utils.sanitizeUri(result[0]);
      if (isSubtitle) {
        this.player.loadExternalSubtitleTrack(uri);
      } else {
        this.player.loadExternalAudioTrack(uri);
      }
    } catch (err) {
      hilog.error(0, 'HPVPlayer', 'pick external track failed: %{public}s', JSON.stringify(err));
    }
  }
}
