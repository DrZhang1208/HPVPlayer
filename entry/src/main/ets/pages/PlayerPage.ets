/**
 * HPVPlayer - 播放器页（独立 router 全屏页，沉浸式）。
 *
 * 手势: 单击显隐控制 / 双击左右快退快进 10s / 水平拖动 seek /
 *       右半屏垂直拖动调音量 / 控制锁定。
 * 官方风格：统一控件规格与圆角，播放器保持黑底沉浸式。
 */
import { router, window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import deviceInfo from '@ohos.deviceInfo';
import {
  Media, MediaOptions, MpvLogLevel, Player, PlayerConfig, PlayerSurface, Playlist, Utils
} from '@mpv-ohos/mpv-arkts';
import { PlayItem, PlayRequest } from '../models/PlayItem';
import { MpvConfigManager } from '../services/MpvConfigManager';
import { SettingsStore } from '../services/SettingsStore';
import { TracksSheet } from '../components/player/TracksSheet';
import { ChaptersSheet } from '../components/player/ChaptersSheet';
import { PlaylistSheet } from '../components/player/PlaylistSheet';
import { SpeedSheet } from '../components/player/SpeedSheet';

const DOMAIN = 0x0000;

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

function formatSigned(seconds: number): string {
  const abs = Math.abs(seconds);
  return `${seconds >= 0 ? '+' : '-'}${Math.round(abs)}s`;
}

@Entry
@ComponentV2
struct PlayerPage {
  @Local player: Player | null = null;
  @Local controlsVisible: boolean = true;
  @Local locked: boolean = false;
  @Local dragValue: number = -1;
  @Local errorText: string = '';
  @Local osdText: string = '';
  @Local showTracks: boolean = false;
  @Local showChapters: boolean = false;
  @Local showPlaylist: boolean = false;
  @Local showSpeed: boolean = false;
  @Local abStage: number = 0; // 0 无 / 1 已设A / 2 循环中
  @Local areaW: number = 1;
  @Local areaH: number = 1;

  private request: PlayRequest | null = null;
  private setupDone: boolean = false;

  // 手势状态
  private touchStartX: number = 0;
  private touchStartY: number = 0;
  private touchStartTime: number = 0;
  private touchDragging: boolean = false;
  private dragAxis: number = 0; // 0 未锁定 / 1 水平 / 2 垂直
  private dragStartPos: number = 0;
  private dragStartVol: number = 100;
  private lastTapTime: number = 0;
  private lastTapX: number = 0;

  // 定时器
  private osdTimer: number = -1;
  private hideTimer: number = -1;
  private tapTimer: number = -1;

  aboutToAppear(): void {
    const params = router.getParams();
    if (params !== null && params !== undefined) {
      this.request = params as PlayRequest;
    }
    this.setup();
  }

  aboutToDisappear(): void {
    this.clearTimer('osd');
    this.clearTimer('hide');
    this.clearTimer('tap');
    this.player?.destroy();
    this.player = null;
    this.setKeepScreenOn(false);
  }

  private async setup(): Promise<void> {
    if (this.setupDone) {
      return;
    }
    this.setupDone = true;
    hilog.info(DOMAIN, 'HPVPlayer', 'player setup: begin');
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      hilog.info(DOMAIN, 'HPVPlayer', 'player setup: got context');
      await SettingsStore.init(context);
      hilog.info(DOMAIN, 'HPVPlayer', 'player setup: settings init done');
      const prefs = await SettingsStore.getPreferencesValue();
      hilog.info(DOMAIN, 'HPVPlayer', 'player setup: prefs loaded');
      const configDir = MpvConfigManager.ensureConfigDir(context);
      hilog.info(DOMAIN, 'HPVPlayer', 'player setup: configDir=%{public}s', configDir);
      this.setKeepScreenOn(true);

      // 模拟器 GL 缺少 GL_EXT_YUV_target，ohcodec interop 初始化失败后
      // mpv vo 线程在 uninit 里 NULL 解引用直接闪退（真机不受影响），强制软解
      const hwdec = prefs.hwdec && !PlayerPage.isEmulator();
      if (prefs.hwdec !== hwdec) {
        hilog.warn(DOMAIN, 'HPVPlayer', 'hwdec disabled on emulator');
      }

      this.player = new Player(new PlayerConfig({
        configDir: configDir,
        logLevel: MpvLogLevel.Info,
        alang: prefs.alang,
        slang: prefs.slang,
        hwdec: hwdec,
        onReady: () => {
          hilog.info(DOMAIN, 'HPVPlayer', 'player surface ready');
          this.openRequest();
        },
      }));
      hilog.info(DOMAIN, 'HPVPlayer', 'player setup: player created');
      this.player.stream.error.listen((msg: string) => {
        this.errorText = msg;
      });
      this.player.stream.playing.listen((playing: boolean) => {
        this.errorText = '';
        if (playing) {
          this.resetHideTimer();
        }
      });
      this.player.stream.message.listen((args: string[]) => {
        // Lua 脚本 script-message 透传
        this.showOsd(args.join('  '));
      });
    } catch (err) {
      hilog.error(DOMAIN, 'HPVPlayer', 'player setup FAILED: %{public}s', JSON.stringify(err));
    }
  }

  private setKeepScreenOn(on: boolean): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    window.getLastWindow(context).then((win) => {
      win.setWindowKeepScreenOn(on);
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, 'HPVPlayer', 'setKeepScreenOn failed: %{public}s', JSON.stringify(err));
    });
  }

  private openRequest(): void {
    if (this.request === null || this.player === null) {
      hilog.warn(DOMAIN, 'HPVPlayer', 'openRequest skipped: request=%{public}d player=%{public}s',
        this.request === null ? 0 : 1, this.player === null ? 'null' : 'ok');
      return;
    }
    const medias = this.request.items.map((item: PlayItem) => PlayerPage.toMedia(item));
    if (medias.length === 0) {
      hilog.warn(DOMAIN, 'HPVPlayer', 'openRequest: empty items');
      return;
    }
    hilog.info(DOMAIN, 'HPVPlayer', 'openRequest: %{public}d items, first=%{public}s',
      medias.length, medias[0].uri);
    this.player.open(new Playlist(medias, Math.min(this.request.index, medias.length - 1)));
  }

  private static isEmulator(): boolean {
    return deviceInfo.productModel === 'emulator';
  }

  private static toMedia(item: PlayItem): Media {
    const options: MediaOptions = {};
    if (item.headers !== undefined) {
      const headers = new Map<string, string>();
      Object.keys(item.headers).forEach((key: string) => {
        headers.set(key, item.headers![key]);
      });
      options.httpHeaders = headers;
    }
    if (item.extraOptions !== undefined) {
      const extras = new Map<string, string>();
      Object.keys(item.extraOptions).forEach((key: string) => {
        extras.set(key, item.extraOptions![key]);
      });
      options.extraOptions = extras;
    }
    return new Media(Utils.sanitizeUri(item.uri), options);
  }

  // ========== 播放控制 ==========

  private get curPosition(): number {
    if (this.dragValue >= 0) {
      return this.dragValue;
    }
    return this.player?.state.position ?? 0;
  }

  private get curDuration(): number {
    return this.player?.state.duration ?? 0;
  }

  private seekTo(seconds: number): void {
    const dur = this.curDuration;
    const target = dur > 0 ? Math.max(0, Math.min(dur, seconds)) : Math.max(0, seconds);
    this.player?.seek(target);
    this.resetHideTimer();
  }

  private toggleControls(): void {
    if (this.locked) {
      return;
    }
    this.controlsVisible = !this.controlsVisible;
    this.resetHideTimer();
  }

  private resetHideTimer(): void {
    this.clearTimer('hide');
    if (this.controlsVisible && !this.locked && (this.player?.state.playing ?? false)) {
      this.hideTimer = setTimeout(() => {
        this.controlsVisible = false;
      }, 4000);
    }
  }

  private showOsd(text: string): void {
    this.osdText = text;
    this.clearTimer('osd');
    this.osdTimer = setTimeout(() => {
      this.osdText = '';
    }, 1500);
  }

  private clearTimer(which: string): void {
    if (which === 'osd' && this.osdTimer >= 0) {
      clearTimeout(this.osdTimer);
      this.osdTimer = -1;
    } else if (which === 'hide' && this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    } else if (which === 'tap' && this.tapTimer >= 0) {
      clearTimeout(this.tapTimer);
      this.tapTimer = -1;
    }
  }

  private cycleAbLoop(): void {
    const player = this.player;
    if (player === null) {
      return;
    }
    if (this.abStage === 0) {
      player.native.setProperty('ab-loop-a', player.state.position);
      this.abStage = 1;
      this.showOsd(`A 点 ${formatTime(player.state.position)}`);
    } else if (this.abStage === 1) {
      player.native.setProperty('ab-loop-b', player.state.position);
      this.abStage = 2;
      this.showOsd(`A-B 循环 ${formatTime(player.state.position)}`);
    } else {
      player.native.setProperty('ab-loop-a', 'none');
      player.native.setProperty('ab-loop-b', 'none');
      this.abStage = 0;
      this.showOsd('A-B 循环已取消');
    }
    this.resetHideTimer();
  }

  // ========== 手势 ==========

  private onTouchEvent(event: TouchEvent): void {
    // SDK 语义: touches 仅含当前活跃触点（Up 时该触点已被移除），
    // Up/Cancel 必须从 changedTouches 取触发点
    let touch: TouchObject | undefined = undefined;
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      if (event.changedTouches.length > 0) {
        touch = event.changedTouches[0];
      }
    } else if (event.touches.length > 0) {
      touch = event.touches[0];
    }
    if (touch === undefined) {
      return;
    }
    switch (event.type) {
      case TouchType.Down:
        this.touchStartX = touch.x;
        this.touchStartY = touch.y;
        this.touchStartTime = Date.now();
        this.touchDragging = false;
        this.dragAxis = 0;
        this.dragStartPos = this.curPosition;
        this.dragStartVol = this.player?.state.volume ?? 100;
        break;
      case TouchType.Move: {
        const dx = touch.x - this.touchStartX;
        const dy = touch.y - this.touchStartY;
        if (this.dragAxis === 0 && (Math.abs(dx) > 15 || Math.abs(dy) > 15)) {
          this.dragAxis = Math.abs(dx) > Math.abs(dy) ? 1 : 2;
        }
        if (this.dragAxis === 1 && this.curDuration > 0) {
          this.touchDragging = true;
          const secondsPerPx = 120 / Math.max(this.areaW, 1);
          const delta = dx * secondsPerPx;
          this.dragValue = Math.max(0, Math.min(this.curDuration, this.dragStartPos + delta));
          this.showOsd(`${formatSigned(this.dragValue - this.dragStartPos)} → ${formatTime(this.dragValue)}`);
        } else if (this.dragAxis === 2 && this.touchStartX > this.areaW / 2) {
          this.touchDragging = true;
          const vol = Math.max(0, Math.min(130, this.dragStartVol - dy / 4));
          this.player?.setVolume(parseFloat(vol.toFixed(0)));
          this.showOsd(`音量 ${Math.round(vol)}`);
        }
        break;
      }
      case TouchType.Up: {
        if (this.touchDragging) {
          if (this.dragValue >= 0) {
            this.player?.seek(this.dragValue);
          }
          this.dragValue = -1;
          this.touchDragging = false;
          this.resetHideTimer();
        } else {
          const dist = Math.hypot(touch.x - this.touchStartX, touch.y - this.touchStartY);
          const elapsed = Date.now() - this.touchStartTime;
          if (dist < 12 && elapsed < 350) {
            this.handleTap(touch.x);
          }
        }
        this.dragAxis = 0;
        break;
      }
      case TouchType.Cancel:
        this.dragValue = -1;
        this.touchDragging = false;
        this.dragAxis = 0;
        break;
      default:
        break;
    }
  }

  private handleTap(x: number): void {
    const now = Date.now();
    if (now - this.lastTapTime < 300 && Math.abs(x - this.lastTapX) < 80) {
      // 双击快进/快退
      this.clearTimer('tap');
      this.lastTapTime = 0;
      const backward = x < this.areaW / 2;
      this.seekTo(this.curPosition + (backward ? -10 : 10));
      this.showOsd(backward ? '« 10 秒' : '10 秒 »');
    } else {
      this.lastTapTime = now;
      this.lastTapX = x;
      this.clearTimer('tap');
      this.tapTimer = setTimeout(() => {
        this.toggleControls();
      }, 300);
    }
  }

  // ========== 构建 ==========

  @Builder
  trackSheetView() {
    TracksSheet({ player: this.player! })
  }

  @Builder
  chapterSheetView() {
    ChaptersSheet({ player: this.player! })
  }

  @Builder
  playlistSheetView() {
    PlaylistSheet({ player: this.player! })
  }

  @Builder
  speedSheetView() {
    SpeedSheet({ player: this.player! })
  }

  @Builder
  actionButton(symbol: Resource, label: string, onTap: () => void, active: boolean = false) {
    Column({ space: 2 }) {
      SymbolGlyph(symbol)
        .fontSize(20)
        .fontColor([active ? $r('app.color.brand') : '#FFD5DAE3'])
      Text(label)
        .fontSize(10)
        .fontColor(active ? $r('app.color.brand') : '#FFD5DAE3')
    }
    .height(48)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 12, right: 12 })
    .borderRadius(12)
    .backgroundColor($r('app.color.player_control_bg'))
    .constraintSize({ minWidth: 56 })
    .onClick(() => onTap())
  }

  @Builder
  topBar() {
    Row({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(24)
        .fontColor(['#FFFFFFFF'])
        .width(36)
        .height(36)
        .backgroundColor($r('app.color.player_control_bg'))
        .borderRadius(18)
        .onClick(() => router.back())

      Column({ space: 2 }) {
        Text(this.titleText())
          .fontSize(16)
          .fontColor(Color.White)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.infoText() !== '') {
          Text(this.infoText())
            .fontSize(11)
            .fontColor('#AAFFFFFF')
            .maxLines(1)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10 })
  }

  @Builder
  bottomBar() {
    Column({ space: 10 }) {
      // 进度条
      Row({ space: 10 }) {
        Text(formatTime(this.curPosition))
          .fontSize(12)
          .fontColor(Color.White)
          .width(48)
          .textAlign(TextAlign.Center)
        Slider({
          value: this.curPosition,
          min: 0,
          max: this.curDuration > 0 ? this.curDuration : 1,
          style: SliderStyle.OutSet,
        })
          .layoutWeight(1)
          .selectedColor($r('app.color.brand'))
          .blockColor(Color.White)
          .trackColor('#55FFFFFF')
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.End) {
              this.player?.seek(value);
              this.dragValue = -1;
              this.resetHideTimer();
            } else {
              this.dragValue = value;
            }
          })
        Text(formatTime(this.curDuration))
          .fontSize(12)
          .fontColor(Color.White)
          .width(48)
          .textAlign(TextAlign.Center)
      }
      .width('100%')

      // 主按钮行
      Row({ space: 22 }) {
        SymbolGlyph($r('sys.symbol.backward_end_fill'))
          .fontSize(26)
          .fontColor(['#FFFFFFFF'])
          .width(40).height(40)
          .onClick(() => {
            this.player?.previous();
            this.resetHideTimer();
          })
        SymbolGlyph($r('sys.symbol.gobackward_10'))
          .fontSize(28)
          .fontColor(['#FFFFFFFF'])
          .width(40).height(40)
          .onClick(() => {
            this.seekTo(this.curPosition - 10);
          })
        SymbolGlyph(this.player!.state.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
          .fontSize(30)
          .fontColor(['#FFFFFFFF'])
          .width(56).height(56)
          .backgroundColor($r('app.color.player_control_bg'))
          .borderRadius(28)
          .onClick(() => {
            this.player?.playOrPause();
            this.resetHideTimer();
          })
        SymbolGlyph($r('sys.symbol.goforward_10'))
          .fontSize(28)
          .fontColor(['#FFFFFFFF'])
          .width(40).height(40)
          .onClick(() => {
            this.seekTo(this.curPosition + 10);
          })
        SymbolGlyph($r('sys.symbol.forward_end_fill'))
          .fontSize(26)
          .fontColor(['#FFFFFFFF'])
          .width(40).height(40)
          .onClick(() => {
            this.player?.next();
            this.resetHideTimer();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)

      // 功能按钮行
      Row({ space: 6 }) {
        this.actionButton($r('sys.symbol.list_bullet'), '列表', () => {
          this.showPlaylist = true;
        })
        this.actionButton($r('sys.symbol.bookmark'), '章节', () => {
          this.showChapters = true;
        })
        this.actionButton($r('sys.symbol.waveform'), '轨道', () => {
          this.showTracks = true;
        })
        this.actionButton($r('sys.symbol.clock_arrow_2_circlepath'),
          this.player!.state.speed !== 1 ? '倍速·开' : '倍速', () => {
            this.showSpeed = true;
          }, this.player!.state.speed !== 1)
        this.actionButton($r('sys.symbol.arrow_counterclockwise'), 'A-B', () => {
          this.cycleAbLoop();
        }, this.abStage > 0)
        this.actionButton($r('sys.symbol.lock_fill'), '锁定', () => {
          this.locked = true;
          this.controlsVisible = false;
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 16 })
    .linearGradient({
      angle: 180,
      colors: [['#00000000', 0], ['#B3000000', 0.55], ['#D9000000', 1]],
    })
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 渲染层
      if (this.player !== null) {
        Stack() {
          PlayerSurface({ player: this.player })
        }
        .width('100%')
        .height('100%')
      } else {
        LoadingProgress().width(44).height(44).color($r('app.color.brand'))
      }

      // 手势区域
      Column()
        .width('100%')
        .height('100%')
        .onTouch((event: TouchEvent) => this.onTouchEvent(event))
        .onAreaChange((_old: Area, newArea: Area) => {
          this.areaW = newArea.width as number;
          this.areaH = newArea.height as number;
        })

      // 中部: 缓冲 / 错误
      if (this.errorText !== '') {
        Text(this.errorText)
          .fontSize(14)
          .fontColor($r('app.color.warning'))
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .backgroundColor('#B3000000')
          .padding(12)
          .borderRadius(8)
      } else if (this.player !== null && this.player.state.buffering && this.osdText === '') {
        Column({ space: 8 }) {
          LoadingProgress().width(44).height(44).color(Color.White)
          if (this.player.state.bufferingPercentage > 0) {
            Text(`${Math.round(this.player.state.bufferingPercentage)}%`)
              .fontSize(14)
              .fontColor(Color.White)
          }
        }
      }

      // OSD
      if (this.osdText !== '') {
        Text(this.osdText)
          .fontSize(15)
          .fontColor(Color.White)
          .backgroundColor('#99000000')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .borderRadius(10)
      }

      // 锁定模式的解锁按钮
      if (this.locked) {
        SymbolGlyph($r('sys.symbol.lock_open_fill'))
          .fontSize(20)
          .fontColor(['#FFFFFFFF'])
          .padding(10)
          .backgroundColor($r('app.color.player_control_bg'))
          .borderRadius(20)
          .position({ x: '88%', y: 48 })
          .onClick(() => {
            this.locked = false;
            this.controlsVisible = true;
            this.resetHideTimer();
          })
      }

      // 顶栏 / 中部留空 / 底栏（顶贴顶、底贴底）
      Column() {
        if (this.controlsVisible && !this.locked) {
          this.topBar()
        }
        Blank()
        if (this.controlsVisible && !this.locked && this.player !== null) {
          this.bottomBar()
        }
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindSheet($$this.showTracks, this.trackSheetView(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: true,
      backgroundColor: $r('app.color.card_background'),
      title: { title: '轨道' },
    })
    .bindSheet($$this.showChapters, this.chapterSheetView(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: true,
      backgroundColor: $r('app.color.card_background'),
      title: { title: '章节' },
    })
    .bindSheet($$this.showPlaylist, this.playlistSheetView(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: true,
      backgroundColor: $r('app.color.card_background'),
      title: { title: '播放列表' },
    })
    .bindSheet($$this.showSpeed, this.speedSheetView(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: true,
      backgroundColor: $r('app.color.card_background'),
      title: { title: '倍速' },
    })
  }

  private titleText(): string {
    const state = this.player?.state;
    if (state === null || state === undefined) {
      return '';
    }
    if (state.title.length > 0) {
      return state.title;
    }
    const idx = state.playlist.index;
    const total = state.playlist.medias.length;
    const media = state.playlist.medias[idx];
    const base = media !== undefined ? media.uri.split('/').pop() ?? '' : '';
    return total > 1 ? `${base} (${idx + 1}/${total})` : base;
  }

  private infoText(): string {
    const state = this.player?.state;
    if (state === null || state === undefined || state.videoParams.w <= 0) {
      return '';
    }
    let info = `${state.videoParams.w}×${state.videoParams.h}`;
    info += state.videoParams.hwPixelFormat !== '' ? ' 硬解' : ' 软解';
    if (state.videoBitrate > 0) {
      info += ` · ${Math.round(state.videoBitrate / 1000)}kbps`;
    }
    if (state.speed !== 1) {
      info += ` · ${state.speed}x`;
    }
    return info;
  }
}
