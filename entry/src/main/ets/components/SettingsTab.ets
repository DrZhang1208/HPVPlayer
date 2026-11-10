/**
 * HPVPlayer - 设置 Tab：播放偏好 / 刮削 / mpv.conf / Lua 脚本完整管理 / 脚本配置。
 * 由 Index（Tabs 容器）内嵌。
 */
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  BUILTIN_SCRIPTS, MpvConfigManager, ScriptEntry
} from '../services/MpvConfigManager';
import { PlayerPreferences, ScrapeConfig, SettingsStore } from '../services/SettingsStore';
import { appNav, NavRoutes } from '../services/AppNav';

const DOMAIN = 0x0000;

@ComponentV2
export struct SettingsTab {
  @Local alang: string = 'chi';
  @Local slang: string = 'chi';
  @Local hwdec: boolean = true;
  @Local scrapeEnabled: boolean = true;
  @Local scrapeKey: string = '';
  @Local scrapeBase: string = 'api.themoviedb.org';
  @Local bangumiEnabled: boolean = true;
  // 弹幕设置（写入 script-opts/danmaku.conf）
  @Local danmakuApi: string = '';
  @Local danmakuFallback: string = '';
  @Local danmakuFontSize: string = '50';
  @Local danmakuOpacity: string = '0.7';
  @Local danmakuDisplayArea: string = '0.85';
  @Local danmakuScrollTime: string = '15';
  @Local danmakuChConvert: number = 0;
  @Local confText: string = '';
  @Local confDirty: boolean = false;
  @Local confPath: string = '';
  @Local scripts: ScriptEntry[] = [];
  @Local scriptsDir: string = '';
  // 脚本查看弹层（只读诊断；插件已内化，不再提供编辑）
  @Local showScriptEditor: boolean = false;
  @Local editorTitle: string = '';
  @Local editorText: string = '';
  private editorEntry: ScriptEntry | null = null;
  // 内置脚本市场弹层
  @Local showBuiltin: boolean = false;
  // script-opts 弹层
  @Local optsNames: string[] = [];

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    SettingsStore.init(context).then(async () => {
      const prefs = await SettingsStore.getPreferencesValue();
      this.alang = prefs.alang;
      this.slang = prefs.slang;
      this.hwdec = prefs.hwdec;
      const scrape = await SettingsStore.getScrapeConfig();
      this.scrapeEnabled = scrape.enabled;
      this.scrapeKey = scrape.apiKey;
      this.scrapeBase = scrape.baseUrl;
      this.bangumiEnabled = scrape.bangumiEnabled;
    });
    this.confPath = MpvConfigManager.ensureConfigDir(context) + '/mpv.conf';
    this.confText = MpvConfigManager.readConf(context);
    this.scriptsDir = MpvConfigManager.configDir(context) + '/scripts';
    this.reloadScripts();
    this.loadDanmakuConf();
  }

  private reloadScripts(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.scripts = MpvConfigManager.listScripts(context);
    this.optsNames = MpvConfigManager.listScriptOpts(context);
  }

  private async savePrefs(): Promise<void> {
    const prefs: PlayerPreferences = {
      alang: this.alang.trim().length > 0 ? this.alang.trim() : 'chi',
      slang: this.slang.trim().length > 0 ? this.slang.trim() : 'chi',
      hwdec: this.hwdec,
    };
    this.alang = prefs.alang;
    this.slang = prefs.slang;
    await SettingsStore.setPreferencesValue(prefs);
    this.toast('已保存，下次播放生效');
  }

  private async saveScrape(): Promise<void> {
    const config: ScrapeConfig = {
      enabled: this.scrapeEnabled,
      apiKey: this.scrapeKey.trim(),
      baseUrl: this.scrapeBase.trim().length > 0 ? this.scrapeBase.trim() : 'api.themoviedb.org',
      bangumiEnabled: this.bangumiEnabled,
    };
    this.scrapeBase = config.baseUrl;
    await SettingsStore.setScrapeConfig(config);
    this.toast('已保存。重新扫描来源即可刮削新条目');
  }

  private saveConf(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    MpvConfigManager.saveConf(context, this.confText);
    this.confDirty = false;
    this.toast('mpv.conf 已保存，下次播放生效');
  }

  private async exportConfig(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const ok = await MpvConfigManager.exportConfig(context);
      if (ok) {
        this.toast('已导出。可在文件管理器中解压编辑 mpv.conf 与脚本');
      }
    } catch (err) {
      hilog.error(DOMAIN, 'HPVPlayer', 'export config failed: %{public}s', JSON.stringify(err));
      this.toast(`导出失败: ${(err as Error).message}`);
    }
  }

  private async importConfig(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const count = await MpvConfigManager.importConfig(context);
      if (count < 0) {
        return; // 用户取消
      }
      // 重新加载到界面
      this.confText = MpvConfigManager.readConf(context);
      this.confDirty = false;
      this.reloadScripts();
      this.toast(`已导入 ${count} 个文件，下次播放生效`);
    } catch (err) {
      hilog.error(DOMAIN, 'HPVPlayer', 'import config failed: %{public}s', JSON.stringify(err));
      this.toast(`导入失败: ${(err as Error).message}`);
    }
  }

  private resetConf(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.confText = MpvConfigManager.resetConf(context);
    this.confDirty = false;
    this.toast('已恢复默认配置');
  }

  // ---------- Lua 脚本 ----------

  private openScriptEditor(entry: ScriptEntry): void {
    this.editorEntry = entry;
    this.editorTitle = entry.name;
    this.editorText = MpvConfigManager.readScript(entry);
    this.showScriptEditor = true;
  }

  private installBuiltin(idx: number): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const script = BUILTIN_SCRIPTS[idx];
    const ok = MpvConfigManager.installBuiltinScript(context, script);
    this.reloadScripts();
    this.toast(ok ? `已安装 ${script.name}` : `${script.name} 已存在`);
  }


  // ---------- 构建 ----------

  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(14)
      .fontColor($r('app.color.text_secondary'))
      .margin({ top: 20, bottom: 8 })
      .padding({ left: 8 })
  }

  @Builder
  scriptRow(script: ScriptEntry) {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.puzzle'))
        .fontSize(20)
        .fontColor([$r('app.color.brand')])
      Column({ space: 2 }) {
        Text(script.name)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(script.enabled ? '已启用' : '已停用')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .onClick(() => this.openScriptEditor(script))

      Toggle({ type: ToggleType.Switch, isOn: script.enabled })
        .onChange((on: boolean) => {
          MpvConfigManager.toggleScript(script, on);
          this.reloadScripts();
        })
      Text('删除')
        .fontSize(13)
        .fontColor($r('app.color.warning'))
        .padding(6)
        .onClick(() => {
          MpvConfigManager.deleteScript(script);
          this.reloadScripts();
          this.toast('已删除');
        })
    }
    .width('100%')
    .padding(14)
    .borderRadius(12)
    .backgroundColor($r('app.color.input_background'))
    .margin({ bottom: 6 })
  }

  @Builder
  builtinRow(scriptIndex: number) {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.download'))
        .fontSize(20)
        .fontColor([$r('app.color.brand')])
      Column({ space: 2 }) {
        Text(BUILTIN_SCRIPTS[scriptIndex].title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text(BUILTIN_SCRIPTS[scriptIndex].description)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text('安装')
        .fontSize(14)
        .fontColor($r('app.color.brand'))
        .height(32)
        .padding({ left: 16, right: 16 })
        .textAlign(TextAlign.Center)
        .backgroundColor($r('app.color.brand_light'))
        .borderRadius(16)
        .onClick(() => this.installBuiltin(scriptIndex))
    }
    .width('100%')
    .padding(14)
    .borderRadius(12)
    .backgroundColor($r('app.color.input_background'))
    .margin({ bottom: 6 })
  }


  @Builder
  scriptEditorSheet() {
    Column({ space: 12 }) {
      Text(this.editorTitle)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 4 })
      // 只读查看：插件已内化，脚本内容随应用更新，不再提供编辑
      Scroll() {
        Text(this.editorText)
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .scrollBar(BarState.Auto)
      .layoutWeight(1)
      .backgroundColor($r('app.color.input_background'))
      .borderRadius(12)
      .align(Alignment.TopStart)
      .margin({ bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20 })
  }

  @Builder
  builtinSheet() {
    Column({ space: 8 }) {
      Text('内置脚本')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 4, bottom: 4 })
      Scroll() {
        Column() {
          ForEach(BUILTIN_SCRIPTS, (script: Record<string, string>, idx: number) => {
            this.builtinRow(idx)
          }, (script: Record<string, string>, idx: number) => `${idx}`)
        }
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, bottom: 24 })
  }

  /** 从文件选择器导入 .conf 到 script-opts/ */
  private async importScriptOpt(): Promise<void> {
    try {
      const docPicker = new picker.DocumentViewPicker();
      const result: string[] = await docPicker.select({
        fileSuffixFilters: ['.conf'],
        maxSelectNumber: 20,
      });
      if (result.length === 0) {
        return;
      }
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let count = 0;
      for (const uri of result) {
        let display = uri.substring(uri.lastIndexOf('/') + 1);
        try {
          display = decodeURIComponent(display);
        } catch (err) {
          // 保留原样
        }
        if (!display.toLowerCase().endsWith('.conf')) {
          display = display + '.conf';
        }
        const text = MpvConfigManager.readUriText(uri);
        if (text.length === 0) {
          continue;
        }
        MpvConfigManager.writeScriptOpt(context, display, text);
        count++;
      }
      this.reloadScripts();
      this.toast(`已导入 ${count} 个配置到 script-opts，下次播放生效`);
    } catch (err) {
      hilog.error(DOMAIN, 'HPVPlayer', 'import opt failed: %{public}s', JSON.stringify(err));
    }
  }

  // ---------- 弹幕设置（script-opts/danmaku.conf） ----------

  private loadDanmakuConf(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const text = MpvConfigManager.readScriptOpt(context, 'danmaku.conf');
      if (text.length === 0) {
        this.danmakuApi = '';
        this.danmakuFallback = '';
        return;
      }
      for (const line of text.split('\n')) {
        const m = line.match(/^\s*([a-zA-Z_]+)\s*=\s*(.*)$/);
        if (m === null) {
          continue;
        }
        const key = m[1];
        let value = m[2].trim().replace(/^["']|["']$/g, '');
        if (key === 'api_server' && this.danmakuApi === '') {
          this.danmakuApi = value.split(',')[0].split('|')[0].split('#')[0].trim();
        } else if (key === 'fallback_server' && this.danmakuFallback === '') {
          this.danmakuFallback = value;
        } else if (key === 'fontsize') {
          this.danmakuFontSize = value;
        } else if (key === 'opacity') {
          this.danmakuOpacity = value;
        } else if (key === 'displayarea') {
          this.danmakuDisplayArea = value;
        } else if (key === 'scrolltime') {
          this.danmakuScrollTime = value;
        } else if (key === 'chConvert') {
          this.danmakuChConvert = parseInt(value) || 0;
        }
      }
    } catch (err) {
      // 无配置文件，用默认
    }
  }

  /** 弹幕服务器输入归一化：裸域名补 https://（脚本 HTTP 桥只认完整 URL） */
  private normalizeServerInput(v: string): string {
    const t = v.trim();
    if (t.length === 0 || t.startsWith('http://') || t.startsWith('https://')) {
      return t;
    }
    return `https://${t}`;
  }

  private saveDanmakuConf(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const lines: string[] = [
      '# HPVPlayer 生成：danmaku 脚本配置（优先级高于脚本默认值）',
      this.danmakuApi.trim().length > 0 ? `api_server=${this.normalizeServerInput(this.danmakuApi)}` : '',
      this.danmakuFallback.trim().length > 0 ? `fallback_server=${this.normalizeServerInput(this.danmakuFallback)}` : '',
      `fontsize=${this.danmakuFontSize.trim() || '50'}`,
      `opacity=${this.danmakuOpacity.trim() || '0.7'}`,
      `displayarea=${this.danmakuDisplayArea.trim() || '0.85'}`,
      `scrolltime=${this.danmakuScrollTime.trim() || '15'}`,
      `chConvert=${this.danmakuChConvert}`,
    ];
    const text = lines.filter((l: string) => l.length > 0).join('\n') + '\n';
    MpvConfigManager.writeScriptOpt(context, 'danmaku.conf', text);
    this.toast('弹幕配置已保存，下次播放生效');
  }

  build() {
    // 同一节点重复 bindSheet 会相互冲突（ArkUI 属性方法重复绑定），
    // 拆两层 Stack 分散绑定
    Stack() {
      Scroll() {
      Column() {
        // ===== 播放偏好 =====
        this.sectionTitle('播放偏好')
        Column({ space: 14 }) {
          Row({ space: 10 }) {
            Text('首选音轨语言')
              .fontSize(16)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
            TextInput({ text: this.alang, placeholder: 'chi' })
              .height(40)
              .fontSize(14)
              .backgroundColor($r('app.color.input_background'))
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_tertiary'))
              .borderRadius(8)
              .width(120)
              .onChange((v: string) => {
                this.alang = v;
              })
          }
          .width('100%')

          Row({ space: 10 }) {
            Text('首选字幕语言')
              .fontSize(16)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
            TextInput({ text: this.slang, placeholder: 'chi' })
              .height(40)
              .fontSize(14)
              .backgroundColor($r('app.color.input_background'))
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_tertiary'))
              .borderRadius(8)
              .width(120)
              .onChange((v: string) => {
                this.slang = v;
              })
          }
          .width('100%')

          Row() {
            Column({ space: 2 }) {
              Text('硬件解码')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
              Text('不可用时自动回退软解')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.hwdec })
              .onChange((on: boolean) => {
                this.hwdec = on;
              })
          }
          .width('100%')

          Button('保存偏好')
            .height(44)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .width('100%')
            .backgroundColor($r('app.color.brand'))
            .fontColor($r('app.color.text_on_brand'))
            .borderRadius(22)
            .onClick(() => this.savePrefs())
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('app.color.card_background'))

        // ===== 刮削 =====
        this.sectionTitle('刮削')
        Column({ space: 14 }) {
          Row() {
            Column({ space: 2 }) {
              Text('自动刮削')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
              Text('扫描后自动匹配海报与简介')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.scrapeEnabled })
              .onChange((on: boolean) => {
                this.scrapeEnabled = on;
              })
          }
          .width('100%')

          Row() {
            Column({ space: 2 }) {
              Text('动漫优先 Bangumi')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
              Text('番组计划开放数据，无需 Key，国内动漫匹配更准')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.bangumiEnabled })
              .onChange((on: boolean) => {
                this.bangumiEnabled = on;
              })
          }
          .width('100%')

          TextInput({ text: this.scrapeKey, placeholder: 'TMDB API Key（v3）' })
            .height(48)
            .fontSize(16)
            .type(InputType.Password)
            .showPasswordIcon(true)
            .backgroundColor($r('app.color.input_background'))
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_tertiary'))
            .borderRadius(12)
            .onChange((v: string) => {
              this.scrapeKey = v;
            })
          TextInput({ text: this.scrapeBase, placeholder: 'api.themoviedb.org（可填镜像域名）' })
            .height(48)
            .fontSize(16)
            .backgroundColor($r('app.color.input_background'))
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_tertiary'))
            .borderRadius(12)
            .onChange((v: string) => {
              this.scrapeBase = v;
            })
          Button('保存刮削配置')
            .height(44)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .width('100%')
            .backgroundColor($r('app.color.brand'))
            .fontColor($r('app.color.text_on_brand'))
            .borderRadius(22)
            .onClick(() => this.saveScrape())
          Text('Key 在 themoviedb.org 免费注册获取（API 设置页）。国内网络不稳定时可配置镜像域名，或让系统代理生效（本应用网络请求默认跟随系统代理）。')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('app.color.card_background'))

        // ===== mpv 配置 =====
        this.sectionTitle('mpv 配置')
        Column({ space: 12 }) {
          Text(this.confPath)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          TextArea({ text: this.confText, placeholder: 'mpv.conf 内容' })
            .height(260)
            .fontSize(12)
            .fontFamily('monospace')
            .backgroundColor($r('app.color.input_background'))
            .fontColor($r('app.color.text_primary'))
            .borderRadius(12)
            .onChange((v: string) => {
              this.confText = v;
              this.confDirty = true;
            })
          Row({ space: 12 }) {
            Button(this.confDirty ? '保存 *' : '保存')
              .height(44)
              .fontSize(16)
              .layoutWeight(1)
              .backgroundColor($r('app.color.brand'))
              .fontColor($r('app.color.text_on_brand'))
              .borderRadius(22)
              .onClick(() => this.saveConf())
            Button('恢复默认')
              .height(44)
              .fontSize(16)
              .layoutWeight(1)
              .backgroundColor($r('app.color.input_background'))
              .fontColor($r('app.color.text_secondary'))
              .borderRadius(22)
              .onClick(() => this.resetConf())
          }
          .width('100%')
          Row({ space: 12 }) {
            Button('配置管理')
              .height(40)
              .fontSize(14)
              .layoutWeight(1)
              .backgroundColor($r('app.color.brand'))
              .fontColor($r('app.color.text_on_brand'))
              .borderRadius(20)
              .onClick(() => appNav.pushPath({ name: NavRoutes.CONFIG_BROWSER }))
            Button('导出到文件管理器')
              .height(40)
              .fontSize(14)
              .layoutWeight(1)
              .backgroundColor($r('app.color.brand_light'))
              .fontColor($r('app.color.brand'))
              .borderRadius(20)
              .onClick(() => this.exportConfig())
            Button('从文件导入')
              .height(40)
              .fontSize(14)
              .layoutWeight(1)
              .backgroundColor($r('app.color.brand_light'))
              .fontColor($r('app.color.brand'))
              .borderRadius(20)
              .onClick(() => this.importConfig())
          }
          .width('100%')
          Text('导出会把 mpv.conf、脚本与配置打包为 zip，可在文件管理器/电脑上解压编辑后导入。')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('app.color.card_background'))

        // ===== Lua 脚本 =====
        this.sectionTitle('Lua 脚本')
        Column({ space: 8 }) {
          if (this.scripts.length === 0) {
            Text('暂无脚本。可安装下方内置脚本。')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ top: 4, bottom: 4 })
          }
          ForEach(this.scripts, (script: ScriptEntry) => {
            this.scriptRow(script)
          }, (script: ScriptEntry) => `${script.name}-${script.enabled}`)

          Row({ space: 8 }) {
            Button('内置脚本')
              .height(40)
              .fontSize(14)
              .layoutWeight(1)
              .backgroundColor($r('app.color.brand'))
              .fontColor($r('app.color.text_on_brand'))
              .borderRadius(20)
              .onClick(() => {
                this.showBuiltin = true;
              })
            Button('导入配置')
              .height(40)
              .fontSize(14)
              .layoutWeight(1)
              .backgroundColor($r('app.color.brand_light'))
              .fontColor($r('app.color.brand'))
              .borderRadius(20)
              .onClick(() => this.importScriptOpt())
          }
          .width('100%')
          .margin({ top: 4 })

          Text(`脚本目录: ${this.scriptsDir}\n插件已内化：仅应用内置脚本可安装运行，外部脚本一律停用；\n点击脚本名可只读查看，开关可启停，删除可移除。`)
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .margin({ top: 4 })
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('app.color.card_background'))

        // ===== 弹幕 =====
        this.sectionTitle('弹幕')
        Column({ space: 14 }) {
          TextInput({ text: this.danmakuApi, placeholder: '弹幕 API 服务器（默认内置公共源）' })
            .height(48)
            .fontSize(15)
            .backgroundColor($r('app.color.input_background'))
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_tertiary'))
            .borderRadius(12)
            .onChange((v: string) => {
              this.danmakuApi = v;
            })
          TextInput({ text: this.danmakuFallback, placeholder: '兜底服务器（B站/爱腾优非动画弹幕）' })
            .height(48)
            .fontSize(15)
            .backgroundColor($r('app.color.input_background'))
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_tertiary'))
            .borderRadius(12)
            .onChange((v: string) => {
              this.danmakuFallback = v;
            })

          Row({ space: 10 }) {
            Text('字号')
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
            TextInput({ text: this.danmakuFontSize })
              .height(40)
              .fontSize(14)
              .backgroundColor($r('app.color.input_background'))
              .fontColor($r('app.color.text_primary'))
              .borderRadius(8)
              .width(90)
              .type(InputType.Number)
              .onChange((v: string) => {
                this.danmakuFontSize = v;
              })
            Text('透明度')
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
              .margin({ left: 8 })
            TextInput({ text: this.danmakuOpacity })
              .height(40)
              .fontSize(14)
              .backgroundColor($r('app.color.input_background'))
              .fontColor($r('app.color.text_primary'))
              .borderRadius(8)
              .width(90)
              .onChange((v: string) => {
                this.danmakuOpacity = v;
              })
          }
          .width('100%')

          Row({ space: 10 }) {
            Text('显示范围')
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
            TextInput({ text: this.danmakuDisplayArea })
              .height(40)
              .fontSize(14)
              .backgroundColor($r('app.color.input_background'))
              .fontColor($r('app.color.text_primary'))
              .borderRadius(8)
              .width(90)
              .onChange((v: string) => {
                this.danmakuDisplayArea = v;
              })
            Text('滚动秒数')
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
              .margin({ left: 8 })
            TextInput({ text: this.danmakuScrollTime })
              .height(40)
              .fontSize(14)
              .backgroundColor($r('app.color.input_background'))
              .fontColor($r('app.color.text_primary'))
              .borderRadius(8)
              .width(90)
              .type(InputType.Number)
              .onChange((v: string) => {
                this.danmakuScrollTime = v;
              })
          }
          .width('100%')

          Row({ space: 8 }) {
            Text('简繁转换')
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
            ForEach([0, 1, 2], (mode: number) => {
              Text(mode === 0 ? '不转换' : mode === 1 ? '简体' : '繁体')
                .fontSize(13)
                .fontColor(this.danmakuChConvert === mode ?
                  $r('app.color.brand') : $r('app.color.text_secondary'))
                .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                .borderRadius(16)
                .backgroundColor(this.danmakuChConvert === mode ?
                  $r('app.color.chip_background') : $r('app.color.input_background'))
                .onClick(() => {
                  this.danmakuChConvert = mode;
                })
            }, (mode: number) => `${mode}`)
          }
          .width('100%')

          Button('保存弹幕配置')
            .height(44)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .width('100%')
            .backgroundColor($r('app.color.brand'))
            .fontColor($r('app.color.text_on_brand'))
            .borderRadius(22)
            .onClick(() => this.saveDanmakuConf())
          Text('服务器需兼容 dandanplay API；完整选项可在「配置管理」中编辑 script-opts/danmaku.conf。')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('app.color.card_background'))

        // ===== 关于 =====
        this.sectionTitle('关于')
        Column({ space: 4 }) {
          Text('HPVPlayer 0.1.0')
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
          Text('内核: libmpv (mpv + ffmpeg, 含 Lua)')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor($r('app.color.card_background'))
        .alignItems(HorizontalAlign.Start)
        .margin({ bottom: 24 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 24 })
      .alignItems(HorizontalAlign.Start)
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .bindSheet($$this.showScriptEditor, this.scriptEditorSheet(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: true,
      backgroundColor: $r('app.color.card_background'),
      title: { title: '查看脚本' },
    })
    .bindSheet($$this.showBuiltin, this.builtinSheet(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: true,
      backgroundColor: $r('app.color.card_background'),
      title: { title: '内置脚本' },
    })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
