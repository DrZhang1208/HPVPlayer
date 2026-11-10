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
import { util } from '@kit.ArkTS';
import { rcp } from '@kit.RemoteCommunicationKit';
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
import { DanmakuSheet } from '../components/player/DanmakuSheet';
import { StatusSheet } from '../components/player/StatusSheet';

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

/**
 * 播放器控制按钮：圆形半透明底 + SymbolGlyph 图标。
 * 独立子组件（非 @Builder 传参）保证点击响应与状态刷新稳定可靠。
 */
@ComponentV2
struct CtlButton {
  @Param symbol: Resource = $r('sys.symbol.info_circle_fill');
  /** 激活态（品牌色高亮） */
  @Param active: boolean = false;
  /** 置灰（功能不可用） */
  @Param dim: boolean = false;
  /** 直径 vp */
  @Param side: number = 34;
  @Param onTap: () => void = () => {};

  build() {
    Row() {
      SymbolGlyph(this.symbol)
        .fontSize(this.side - 10)
        .fontColor([this.active ? $r('app.color.brand') :
          (this.dim ? '#80D5DAE3' : '#FFF2F4F8')])
    }
    .width(this.side)
    .height(this.side)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(this.side / 2)
    .backgroundColor($r('app.color.player_control_bg'))
    .onClick(() => {
      hilog.info(DOMAIN, 'HPVPlayer', 'ctl button tapped');
      this.onTap();
    })
  }
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
  @Local showDanmaku: boolean = false;
  @Local showStatus: boolean = false;
  @Local danmakuOn: boolean = false; // 内置弹幕脚本可用
  @Local danmakuShown: boolean = false; // 弹幕当前显示状态（随开关/加载同步）
  @Local tracksFocus: string = ''; // 轨道面板聚焦：'' 全部 / 'audio' 音轨 / 'subs' 字幕
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
      this.ensureDanmakuScript();
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
        // Lua 脚本 script-message 透传；过滤脚本间内部协议消息（如 xxx-version 握手）
        if (args.length === 0) {
          return;
        }
        const head = args[0];
        if (head === 'hpv-fetch' && args.length >= 4) {
          // danmaku 脚本 HTTP 桥：沙箱无 curl，App 代为请求后经 user-data 属性回传
          // 协议: hpv-fetch <reqId> <method> <url> <base64(headersJson)> <base64(body)>
          this.serveHpvFetch(args[1], args[2], args[3], args.length > 4 ? args[4] : '',
            args.length > 5 ? args[5] : '');
          return;
        }
        if (head.endsWith('-version') || head === 'keybinding' ||
          head.startsWith('uosc/') || head.startsWith('danmaku/')) {
          return;
        }
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
    this.danmakuOn = this.hasDanmakuScriptSafe();
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

  /** 已缓冲比例 0~1（buffer 秒 / 总时长） */
  private bufferPercent(): number {
    const state = this.player?.state;
    if (state === null || state === undefined || state.duration <= 0) {
      return 0;
    }
    return Math.max(0, Math.min(1, state.buffer / state.duration));
  }

  private seekTo(seconds: number): void {
    const dur = this.curDuration;
    const target = dur > 0 ? Math.max(0, Math.min(dur, seconds)) : Math.max(0, seconds);
    this.player?.seek(target);
    this.resetHideTimer();
  }

  /**
   * 控件点击后调用：根节点 onTouch 兜底会把按钮点击也送进手势状态机，
   * 导致"点按钮 300ms 后控制栏被隐藏 / 快速连点两个按钮触发双击快进"。
   * 在 onClick（晚于冒泡 Up 事件触发）里清掉待触发的 tap 定时器和双击判定。
   */
  private consumeTapGesture(): void {
    this.clearTimer('tap');
    this.lastTapTime = 0;
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

  // ========== 弹幕 (内置 danmaku Lua 脚本联动) ==========

  /** 确保内置弹幕脚本已安装（首次播放自动装，已装不覆盖） */
  private ensureDanmakuScript(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      MpvConfigManager.installDanmaku(context);
    } catch (err) {
      hilog.warn(DOMAIN, 'HPVPlayer', 'install danmaku failed: %{public}s', JSON.stringify(err));
    }
    this.danmakuOn = MpvConfigManager.hasDanmaku(context);
  }

  /** 弹幕开关：脚本 show_danmaku_keyboard 消息切换显隐并自行渲染/清屏 */
  private toggleDanmakuVisibility(): void {
    if (!this.danmakuOn) {
      this.showOsd('弹幕脚本不可用');
      return;
    }
    if (this.player === null) {
      return;
    }
    this.consumeTapGesture();
    this.danmakuShown = !this.danmakuShown;
    this.player.native.command(['script-message', 'show_danmaku_keyboard']);
    this.showOsd(this.danmakuShown ? '弹幕开' : '弹幕关');
    this.resetHideTimer();
  }

  private hasDanmakuScriptSafe(): boolean {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      return MpvConfigManager.hasDanmaku(context);
    } catch (err) {
      return false;
    }
  }

  /** danmaku 脚本 HTTP 桥：App 代请求，结果 base64 写回 user-data 属性 */
  private serveHpvFetch(reqId: string, method: string, url: string,
    headersB64: string, bodyB64: string): void {
    const player = this.player;
    if (player === null) {
      return;
    }
    const prop = `user-data/hpv-fetch/${reqId}`;
    const helper = new util.Base64Helper();
    const decoder = util.TextDecoder.create('utf-8');
    let headers: Record<string, string> = {};
    let content: string | undefined = undefined;
    try {
      if (headersB64.length > 0) {
        const json = decoder.decodeToString(helper.decodeSync(headersB64));
        if (json.length > 2) {
          const parsed = JSON.parse(json) as Record<string, string>;
          if (parsed !== null) {
            headers = parsed;
          }
        }
      }
      if (bodyB64.length > 0) {
        content = decoder.decodeToString(helper.decodeSync(bodyB64));
      }
    } catch (err) {
      // 头/体解析失败按裸 GET 处理，不至于让请求挂死
      hilog.warn(DOMAIN, 'HPVPlayer', 'hpv-fetch param decode failed: %{public}s', JSON.stringify(err));
    }
    const session = rcp.createSession();
    session.fetch(new rcp.Request(url, method, headers, content)).then((response) => {
      if (response.statusCode !== 200 || response.body === undefined) {
        player.native.setProperty(prop, `err:HTTP ${response.statusCode}`);
        return;
      }
      const body = response.toString() ?? '';
      const bytes = new util.TextEncoder().encodeInto(body);
      player.native.setProperty(prop, helper.encodeToStringSync(bytes));
    }).catch((err: BusinessError) => {
      player.native.setProperty(prop, `err:${err.message ?? 'network'}`);
    }).finally(() => {
      session.close();
    });
  }

  // ========== 手势 ==========

  private onTouchEvent(event: TouchEvent): void {
    hilog.info(DOMAIN, 'HPVPlayer', 'gesture touch: %{public}s touches=%{public}d changed=%{public}d',
      event.type, event.touches.length, event.changedTouches.length);
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
      hilog.warn(DOMAIN, 'HPVPlayer', 'gesture touch: NO TOUCH OBJECT, drop');
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
    TracksSheet({ player: this.player!, focus: this.tracksFocus })
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
  danmakuSheetView() {
    DanmakuSheet({
      player: this.player,
      mediaTitle: this.titleText(),
      onDanmakuLoaded: () => {
        this.danmakuShown = true;
      },
    })
  }

  @Builder
  statusSheetView() {
    StatusSheet({ player: this.player! })
  }

  /** 控制行紧凑图标按钮尺寸（按可用宽度自适应大小） */
  private ctlSize(): number {
    // 12 个控件同排一行：宽不足时按比例收缩（平板/横屏满配 34，窄屏最小 26）
    const usable = this.areaW - 24;
    const full = 12 * 34 + 46 + 12;
    return Math.max(26, Math.floor(34 * Math.min(1, usable / full)));
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
        .onClick(() => {
          this.consumeTapGesture();
          router.back();
        })

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

      // 锁定（顶栏右侧，控制行保持单行三簇）
      CtlButton({
        symbol: $r('sys.symbol.lock_fill'),
        side: 36,
        onTap: () => {
          this.consumeTapGesture();
          this.locked = true;
          this.controlsVisible = false;
        },
      })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10 })
  }

  @Builder
  bottomBar() {
    Column({ space: 10 }) {
      // 进度条（含缓冲条）
      Row({ space: 10 }) {
        Text(formatTime(this.curPosition))
          .fontSize(12)
          .fontColor(Color.White)
          .width(48)
          .textAlign(TextAlign.Center)
        Stack({ alignContent: Alignment.Start }) {
          // 已缓冲长度（底层轨道上叠白色半透明）
          Row()
            .width(this.bufferPercent() > 0 ? `${this.bufferPercent() * 100}%` : '0vp')
            .height(3)
            .borderRadius(2)
            .backgroundColor('#66FFFFFF')
            .margin({ left: 6 })
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
        }
        .layoutWeight(1)
        Text(formatTime(this.curDuration))
          .fontSize(12)
          .fontColor(Color.White)
          .width(48)
          .textAlign(TextAlign.Center)
      }
      .width('100%')

      // 控制行（一行三簇：左 信息+弹幕 / 中 播放控制 / 右 设置+轨道）
      Row({ space: 2 }) {
        // 居左：视频信息 / 弹幕开关 / 弹幕设置（两侧 layoutWeight 等分，保证中簇真正居中）
        Row({ space: 4 }) {
          CtlButton({
            symbol: $r('sys.symbol.info_circle_fill'),
            side: this.ctlSize(),
            onTap: () => {
              this.consumeTapGesture();
              this.showStatus = true;
              this.resetHideTimer();
            },
          })
          CtlButton({
            symbol: $r('sys.symbol.text_alignleft'),
            side: this.ctlSize(),
            active: this.danmakuShown && this.danmakuOn,
            dim: !this.danmakuOn,
            onTap: () => {
              this.toggleDanmakuVisibility();
            },
          })
          CtlButton({
            symbol: $r('sys.symbol.slider_horizontal_2'),
            side: this.ctlSize(),
            onTap: () => {
              this.consumeTapGesture();
              this.showDanmaku = true;
              this.resetHideTimer();
            },
          })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Start)
        .alignItems(VerticalAlign.Center)

        // 居中：上一个 / 后退10秒 / 播放暂停 / 前进10秒 / 下一个
        Row({ space: 14 }) {
          SymbolGlyph($r('sys.symbol.backward_end_fill'))
            .fontSize(this.ctlSize() - 8)
            .fontColor(['#FFFFFFFF'])
            .width(this.ctlSize())
            .height(this.ctlSize())
            .onClick(() => {
              this.consumeTapGesture();
              this.player?.previous();
              this.resetHideTimer();
            })
          SymbolGlyph($r('sys.symbol.gobackward_10'))
            .fontSize(this.ctlSize() - 6)
            .fontColor(['#FFFFFFFF'])
            .width(this.ctlSize())
            .height(this.ctlSize())
            .onClick(() => {
              this.consumeTapGesture();
              this.seekTo(this.curPosition - 10);
            })
          SymbolGlyph(this.player!.state.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
            .fontSize(this.ctlSize() + 4)
            .fontColor(['#FFFFFFFF'])
            .width(this.ctlSize() + 12)
            .height(this.ctlSize() + 12)
            .backgroundColor($r('app.color.player_control_bg'))
            .borderRadius((this.ctlSize() + 12) / 2)
            .onClick(() => {
              this.consumeTapGesture();
              this.player?.playOrPause();
              this.resetHideTimer();
            })
          SymbolGlyph($r('sys.symbol.goforward_10'))
            .fontSize(this.ctlSize() - 6)
            .fontColor(['#FFFFFFFF'])
            .width(this.ctlSize())
            .height(this.ctlSize())
            .onClick(() => {
              this.consumeTapGesture();
              this.seekTo(this.curPosition + 10);
            })
          SymbolGlyph($r('sys.symbol.forward_end_fill'))
            .fontSize(this.ctlSize() - 8)
            .fontColor(['#FFFFFFFF'])
            .width(this.ctlSize())
            .height(this.ctlSize())
            .onClick(() => {
              this.consumeTapGesture();
              this.player?.next();
              this.resetHideTimer();
            })
        }
        .alignItems(VerticalAlign.Center)

        // 居右：倍速 / 音轨 / 字幕轨 / 章节 / 列表
        Row({ space: 4 }) {
          Text(`${this.player!.state.speed}x`)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.player!.state.speed !== 1 ?
              $r('app.color.brand') : '#FFF2F4F8')
            .height(this.ctlSize())
            .constraintSize({ minWidth: this.ctlSize() })
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.consumeTapGesture();
              this.showSpeed = true;
              this.resetHideTimer();
            })
          CtlButton({
            symbol: $r('sys.symbol.waveform_circle'),
            side: this.ctlSize(),
            onTap: () => {
              this.consumeTapGesture();
              this.tracksFocus = 'audio';
              this.showTracks = true;
              this.resetHideTimer();
            },
          })
          CtlButton({
            symbol: $r('sys.symbol.character_textbox'),
            side: this.ctlSize(),
            onTap: () => {
              this.consumeTapGesture();
              this.tracksFocus = 'subs';
              this.showTracks = true;
              this.resetHideTimer();
            },
          })
          CtlButton({
            symbol: $r('sys.symbol.list_number'),
            side: this.ctlSize(),
            onTap: () => {
              this.consumeTapGesture();
              this.showChapters = true;
              this.resetHideTimer();
            },
          })
          CtlButton({
            symbol: $r('sys.symbol.line_3_horizontal'),
            side: this.ctlSize(),
            onTap: () => {
              this.consumeTapGesture();
              this.showPlaylist = true;
              this.resetHideTimer();
            },
          })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.End)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
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

      // 手势区域（Block: XComponent SURFACE 合成层会竞争触摸，必须显式拦截）
      Column()
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Block)
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

      // 顶栏 / 中部留空 / 底栏（顶贴顶、底贴底；None: 空白区域穿透到手势层）
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
      .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    // 兜底：模拟器上 SURFACE 型 XComponent 的独立合成层可能吞掉兄弟节点触摸，
    // 根节点同时接收（Transparent 不影响子节点已处理的事件）
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down || event.type === TouchType.Move) {
        hilog.debug(DOMAIN, 'HPVPlayer', 'root fallback touch: %{public}s', event.type);
      }
      this.onTouchEvent(event);
    })
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
    .bindSheet($$this.showDanmaku, this.danmakuSheetView(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: true,
      backgroundColor: $r('app.color.card_background'),
      title: { title: '弹幕' },
    })
    .bindSheet($$this.showStatus, this.statusSheetView(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: true,
      backgroundColor: $r('app.color.card_background'),
      title: { title: '视频信息' },
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
    // HDR / 杜比视界标签（BT.2020 + PQ）
    const vp = state.videoParams;
    if (vp.primaries.includes('2020') && (vp.gamma.includes('pq') || vp.gamma.includes('2084'))) {
      info += ' · HDR';
    }
    if (state.videoBitrate > 0) {
      info += ` · ${Math.round(state.videoBitrate / 1000)}kbps`;
    }
    if (state.speed !== 1) {
      info += ` · ${state.speed}x`;
    }
    // 字幕/音轨（选中轨道的语言或标题）
    const sub = state.track.subs;
    if (sub.id !== 'no' && (sub.lang.length > 0 || sub.title.length > 0)) {
      info += ` · 字幕 ${sub.lang.length > 0 ? sub.lang : sub.title}`;
    }
    const audio = state.track.audio;
    if (audio.id !== 'no' && (audio.lang.length > 0 || audio.title.length > 0)) {
      info += ` · 音轨 ${audio.lang.length > 0 ? audio.lang : audio.title}`;
    }
    return info;
  }
}