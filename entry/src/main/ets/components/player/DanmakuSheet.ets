/**
 * HPVPlayer - 弹幕面板（原生 UI 替代脚本的 uosc/console 菜单）。
 * 搜索 dandanplay → 选番剧 → 选集 → App 拉取弹幕写本地 XML →
 * script-message add-source-event 交给内置 Lua 脚本解析渲染（脚本全程不发 HTTP）。
 * 另含弹幕样式（大小/透明度/显示范围/彩色）：hpv-set-style 实时生效并写回 danmaku.conf。
 */
import { Player } from '@mpv-ohos/mpv-arkts';
import { common } from '@kit.AbilityKit';
import { DanmakuAnimeResult, DanmakuClient, DanmakuEpisodeResult } from '../../services/DanmakuClient';
import { MpvConfigManager } from '../../services/MpvConfigManager';

@ComponentV2
export struct DanmakuSheet {
  @Param player: Player | null = null;
  @Param mediaTitle: string = '';
  /** 弹幕加载成功后回调（PlayerPage 同步开关按钮状态） */
  @Param onDanmakuLoaded: () => void = () => {};
  @Local keyword: string = '';
  @Local searching: boolean = false;
  @Local searchError: string = '';
  @Local animes: DanmakuAnimeResult[] = [];
  @Local expandedAnimeId: number = -1;
  @Local episodesLoading: boolean = false;
  @Local episodes: DanmakuEpisodeResult[] = [];
  @Local loadedEpisodeTitle: string = '';
  @Local delayText: string = '0';
  /** 正在拉取弹幕的集（-1 = 空闲） */
  @Local loadingEpisodeId: number = -1;
  // 弹幕样式（默认值与脚本 options.lua 保持一致）
  @Local styleFontsize: number = 50;
  @Local styleOpacity: number = 0.7;
  @Local styleDisplayarea: number = 0.85;
  @Local styleColor: boolean = true;

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const text = MpvConfigManager.readScriptOpt(context, 'danmaku.conf');
    if (text.length === 0) {
      return;
    }
    for (const line of text.split('\n')) {
      const m = line.match(/^\s*(fontsize|opacity|displayarea|color|scroll_only)\s*=\s*(.+)$/);
      if (m === null) {
        continue;
      }
      const raw = m[2].trim().replace(/^["']|["']$/g, '');
      if (m[1] === 'fontsize') {
        const v = Number(raw);
        if (Number.isFinite(v) && v > 0) {
          this.styleFontsize = Math.floor(v);
        }
      } else if (m[1] === 'opacity') {
        const v = Number(raw);
        if (Number.isFinite(v) && v > 0 && v <= 1) {
          this.styleOpacity = v;
        }
      } else if (m[1] === 'displayarea') {
        const v = Number(raw);
        if (Number.isFinite(v) && v > 0 && v <= 1) {
          this.styleDisplayarea = v;
        }
      } else if (m[1] === 'color') {
        this.styleColor = raw !== 'no' && raw !== 'false' && raw !== '0';
      }
    }
  }

  /** 实时下发给脚本并持久化到 script-opts/danmaku.conf */
  private applyStyle(key: string, value: string): void {
    this.persistStyleOpt(key, value);
    if (this.player === null) {
      return;
    }
    this.player.native.command(['script-message', 'hpv-set-style', key, value]);
  }

  /** 在 danmaku.conf 中按 key 更新或追加一行，保留其它配置 */
  private persistStyleOpt(key: string, value: string): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const name = 'danmaku.conf';
    let text = MpvConfigManager.readScriptOpt(context, name);
    if (text.length === 0) {
      text = `# danmaku script options\n${key}=${value}\n`;
    } else {
      const lines = text.split('\n');
      let found = false;
      for (let i = 0; i < lines.length; i++) {
        const m = lines[i].match(/^\s*([A-Za-z_][A-Za-z_0-9]*)\s*=/);
        if (m !== null && m[1] === key) {
          lines[i] = `${key}=${value}`;
          found = true;
          break;
        }
      }
      if (!found) {
        lines.push(`${key}=${value}`);
      }
      text = lines.join('\n');
    }
    MpvConfigManager.writeScriptOpt(context, name, text);
  }

  private search(): void {
    const kw = this.keyword.trim();
    if (kw.length === 0) {
      this.searchError = '请输入番剧名称';
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.searching = true;
    this.searchError = '';
    this.animes = [];
    this.expandedAnimeId = -1;
    this.episodes = [];
    DanmakuClient.search(context, kw).then((results: DanmakuAnimeResult[]) => {
      this.animes = results;
      this.searching = false;
      if (results.length > 0) {
        this.expandAnime(results[0]);
      } else {
        this.searchError = '没有找到匹配的番剧，可尝试英文名或简称';
      }
    }).catch((err: BusinessError) => {
      this.searchError = (err as Error).message;
      this.searching = false;
    });
  }

  /** 展开番剧 → 懒加载分集（搜索接口不返回分集） */
  private expandAnime(anime: DanmakuAnimeResult): void {
    this.expandedAnimeId = anime.animeId;
    this.episodes = [];
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.episodesLoading = true;
    DanmakuClient.fetchEpisodes(context, anime.animeId).then((eps: DanmakuEpisodeResult[]) => {
      this.episodes = eps;
      this.episodesLoading = false;
      if (eps.length === 0) {
        this.searchError = '该番剧没有可用分集';
      }
    }).catch((err: BusinessError) => {
      this.episodesLoading = false;
      this.searchError = (err as Error).message;
    });
  }

  private loadEpisode(anime: DanmakuAnimeResult, ep: DanmakuEpisodeResult): void {
    const player = this.player;
    if (player === null || this.loadingEpisodeId !== -1) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.loadingEpisodeId = ep.episodeId;
    this.searchError = '';
    DanmakuClient.fetchCommentsFile(context, ep.episodeId).then((result) => {
      // 脚本原生本地弹幕源路径：解析 XML → 入 sources → 渲染
      player.native.command(['script-message', 'add-source-event', result.path]);
      // 重发当前延迟设置，让脚本按已选延迟渲染
      player.native.command(['script-message', 'danmaku-delay', this.delayText]);
      this.loadedEpisodeTitle = `${anime.title} · ${ep.title}（${result.count}条）`;
      this.onDanmakuLoaded();
    }).catch((err: BusinessError) => {
      this.searchError = (err as Error).message;
    }).finally(() => {
      this.loadingEpisodeId = -1;
    });
  }

  private setDelay(seconds: number): void {
    if (this.player === null) {
      return;
    }
    this.delayText = `${seconds}`;
    this.player.native.command(['script-message', 'danmaku-delay', `${seconds}`]);
  }

  build() {
    Column({ space: 12 }) {
      // 搜索框
      Row({ space: 10 }) {
        TextInput({ text: this.keyword, placeholder: this.mediaTitle.length > 0 ?
          `番剧名称（默认: ${this.mediaTitle.substring(0, 12)}）` : '番剧名称' })
          .height(44)
          .fontSize(15)
          .backgroundColor($r('app.color.input_background'))
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_tertiary'))
          .borderRadius(12)
          .layoutWeight(1)
          .onChange((v: string) => {
            this.keyword = v;
          })
          .onSubmit(() => this.search())
        Button('搜索')
          .height(40)
          .fontSize(14)
          .backgroundColor($r('app.color.brand'))
          .fontColor($r('app.color.text_on_brand'))
          .borderRadius(20)
          .onClick(() => this.search())
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4 })

      // 已加载提示
      if (this.loadedEpisodeTitle !== '') {
        Text(`已加载: ${this.loadedEpisodeTitle}`)
          .fontSize(12)
          .fontColor($r('app.color.brand'))
          .width('100%')
          .padding({ left: 16 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      // 延迟控制
      Row({ space: 8 }) {
        Text('延迟')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
        ForEach([-3, -1, 0, 1, 3], (sec: number) => {
          Text(`${sec > 0 ? '+' : ''}${sec}s`)
            .fontSize(12)
            .fontColor(this.delayText === `${sec}` ?
              $r('app.color.brand') : $r('app.color.text_secondary'))
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .borderRadius(12)
            .backgroundColor(this.delayText === `${sec}` ?
              $r('app.color.chip_background') : $r('app.color.input_background'))
            .onClick(() => this.setDelay(sec))
        }, (sec: number) => `${sec}`)
        Blank()
      }
      .width('100%')
      .padding({ left: 16, right: 16 })

      // 弹幕样式（实时生效，滑动结束才下发）
      Column({ space: 10 }) {
        Text('弹幕样式')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
        Row({ space: 10 }) {
          Text('大小').fontSize(13).fontColor($r('app.color.text_secondary')).width(60)
          Slider({ value: this.styleFontsize, min: 20, max: 90, step: 1 })
            .layoutWeight(1)
            .selectedColor($r('app.color.brand'))
            .blockColor($r('app.color.brand'))
            .trackColor($r('app.color.input_background'))
            .onChange((value: number, mode: SliderChangeMode) => {
              if (mode === SliderChangeMode.End) {
                this.styleFontsize = Math.floor(value);
                this.applyStyle('fontsize', `${this.styleFontsize}`);
              } else if (mode === SliderChangeMode.Click) {
                this.styleFontsize = Math.floor(value);
                this.applyStyle('fontsize', `${this.styleFontsize}`);
              } else {
                this.styleFontsize = Math.floor(value);
              }
            })
          Text(`${this.styleFontsize}`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width(32)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        Row({ space: 10 }) {
          Text('透明度').fontSize(13).fontColor($r('app.color.text_secondary')).width(60)
          Slider({ value: this.styleOpacity, min: 0.1, max: 1, step: 0.05 })
            .layoutWeight(1)
            .selectedColor($r('app.color.brand'))
            .blockColor($r('app.color.brand'))
            .trackColor($r('app.color.input_background'))
            .onChange((value: number, mode: SliderChangeMode) => {
              if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                this.styleOpacity = Number(value.toFixed(2));
                this.applyStyle('opacity', `${this.styleOpacity}`);
              } else {
                this.styleOpacity = Number(value.toFixed(2));
              }
            })
          Text(this.styleOpacity.toFixed(2).replace(/0$/, ''))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width(32)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        Row({ space: 10 }) {
          Text('范围').fontSize(13).fontColor($r('app.color.text_secondary')).width(60)
          Slider({ value: this.styleDisplayarea, min: 0.3, max: 1, step: 0.05 })
            .layoutWeight(1)
            .selectedColor($r('app.color.brand'))
            .blockColor($r('app.color.brand'))
            .trackColor($r('app.color.input_background'))
            .onChange((value: number, mode: SliderChangeMode) => {
              if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                this.styleDisplayarea = Number(value.toFixed(2));
                this.applyStyle('displayarea', `${this.styleDisplayarea}`);
              } else {
                this.styleDisplayarea = Number(value.toFixed(2));
              }
            })
          Text(`${Math.round(this.styleDisplayarea * 100)}%`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width(32)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        Row({ space: 8 }) {
          Text('彩色弹幕')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
          Toggle({ type: ToggleType.Switch, isOn: this.styleColor })
            .selectedColor($r('app.color.brand'))
            .onChange((isOn: boolean) => {
              this.styleColor = isOn;
              this.applyStyle('color', isOn ? 'true' : 'false');
            })
          Blank()
          Text('（本次立即生效，并写入配置）')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 2, bottom: 6 })
      .borderRadius(12)
      .backgroundColor($r('app.color.input_background'))
      .margin({ left: 12, right: 12 })

      // 状态
      if (this.searching) {
        Column({ space: 8 }) {
          LoadingProgress().width(32).height(32).color($r('app.color.brand'))
          Text('搜索中…')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .padding({ top: 20 })
      } else if (this.searchError !== '') {
        Text(this.searchError)
          .fontSize(13)
          .fontColor($r('app.color.warning'))
          .width('100%')
          .padding({ left: 16, top: 8 })
      }

      // 结果列表（番剧 → 展开 分集）
      if (this.animes.length > 0) {
        Scroll() {
          Column() {
            ForEach(this.animes, (anime: DanmakuAnimeResult) => {
              Column({ space: 0 }) {
                // 番剧头
                Row({ space: 10 }) {
                  SymbolGlyph(this.expandedAnimeId === anime.animeId ?
                    $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
                    .fontSize(14)
                    .fontColor([$r('app.color.text_tertiary')])
                  Text(anime.title)
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                }
                .width('100%')
                .height(52)
                .padding({ left: 16, right: 16 })
                .onClick(() => {
                  if (this.expandedAnimeId === anime.animeId) {
                    this.expandedAnimeId = -1;
                  } else {
                    this.expandAnime(anime);
                  }
                })

                // 分集列表（懒加载）
                if (this.expandedAnimeId === anime.animeId) {
                  if (this.episodesLoading) {
                    Row({ space: 8 }) {
                      LoadingProgress().width(20).height(20).color($r('app.color.brand'))
                      Text('加载分集…')
                        .fontSize(13)
                        .fontColor($r('app.color.text_secondary'))
                    }
                    .width('100%')
                    .height(44)
                    .justifyContent(FlexAlign.Center)
                  } else {
                    ForEach(this.episodes, (ep: DanmakuEpisodeResult, idx: number) => {
                      Row({ space: 10 }) {
                        Text(`${idx + 1}`)
                          .fontSize(13)
                          .fontColor($r('app.color.brand'))
                          .width(28)
                          .textAlign(TextAlign.Center)
                        Text(ep.title)
                          .fontSize(14)
                          .fontColor($r('app.color.text_primary'))
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .layoutWeight(1)
                        if (this.loadingEpisodeId === ep.episodeId) {
                          LoadingProgress().width(18).height(18).color($r('app.color.brand'))
                        } else {
                          Text('加载')
                            .fontSize(12)
                            .fontColor($r('app.color.brand'))
                            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                            .borderRadius(12)
                            .backgroundColor($r('app.color.chip_background'))
                        }
                      }
                      .width('100%')
                      .height(44)
                      .padding({ left: 30, right: 16 })
                      .onClick(() => this.loadEpisode(anime, ep))
                    }, (ep: DanmakuEpisodeResult) => `${ep.episodeId}`)
                  }
                }
              }
              .borderRadius(12)
              .backgroundColor($r('app.color.input_background'))
              .margin({ left: 12, right: 12, bottom: 8 })
            }, (anime: DanmakuAnimeResult) => `${anime.animeId}-${this.expandedAnimeId === anime.animeId}`)
          }
          .width('100%')
          .padding({ bottom: 16 })
        }
        .scrollBar(BarState.Off)
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
  }
}
