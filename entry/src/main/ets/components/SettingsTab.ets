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
import { PlayLauncher } from '../services/PlayLauncher';

const DOMAIN = 0x0000;

@ComponentV2
export struct SettingsTab {
  @Local alang: string = 'chi';
  @Local slang: string = 'chi';
  @Local hwdec: boolean = true;
  @Local scrapeEnabled: boolean = true;
  @Local scrapeKey: string = '';
  @Local scrapeBase: string = 'api.themoviedb.org';
  @Local confText: string = '';
  @Local confDirty: boolean = false;
  @Local confPath: string = '';
  @Local scripts: ScriptEntry[] = [];
  @Local scriptsDir: string = '';
  // 脚本查看/编辑弹层
  @Local showScriptEditor: boolean = false;
  @Local editorTitle: string = '';
  @Local editorText: string = '';
  @Local editorSaving: boolean = false;
  private editorEntry: ScriptEntry | null = null;
  // 内置脚本市场弹层
  @Local showBuiltin: boolean = false;
  // script-opts 弹层
  @Local showOpts: boolean = false;
  @Local optsNames: string[] = [];
  @Local showOptEditor: boolean = false;
  @Local optName: string = '';
  @Local optText: string = '';
  // 新建脚本弹层
  @Local showNewScript: boolean = false;
  @Local newScriptName: string = '';

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
    });
    this.confPath = MpvConfigManager.ensureConfigDir(context) + '/mpv.conf';
    this.confText = MpvConfigManager.readConf(context);
    this.scriptsDir = MpvConfigManager.configDir(context) + '/scripts';
    this.reloadScripts();
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

  private resetConf(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.confText = MpvConfigManager.resetConf(context);
    this.confDirty = false;
    this.toast('已恢复默认配置');
  }

  // ---------- Lua 脚本 ----------

  private async importScript(): Promise<void> {
    try {
      const docPicker = new picker.DocumentViewPicker();
      const result: string[] = await docPicker.select({
        fileSuffixFilters: ['.lua'],
        maxSelectNumber: 20,
      });
      if (result.length === 0) {
        return;
      }
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let count = 0;
      for (const uri of result) {
        const name = PlayLauncher.baseName(uri);
        MpvConfigManager.importScript(context, uri, name);
        count++;
      }
      this.reloadScripts();
      this.toast(`已导入 ${count} 个脚本`);
    } catch (err) {
      hilog.error(DOMAIN, 'HPVPlayer', 'import script failed: %{public}s', JSON.stringify(err));
    }
  }

  private openScriptEditor(entry: ScriptEntry): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.editorEntry = entry;
    this.editorTitle = entry.name;
    this.editorText = MpvConfigManager.readScript(entry);
    this.editorSaving = false;
    this.showScriptEditor = true;
  }

  private saveScriptEditor(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (this.editorEntry !== null) {
      MpvConfigManager.writeScript(this.editorEntry, this.editorText);
      this.toast('脚本已保存，下次播放生效');
    }
    this.showScriptEditor = false;
  }

  private createScript(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const name = this.newScriptName.trim();
    if (name.length === 0) {
      this.toast('请输入脚本名');
      return;
    }
    const finalName = MpvConfigManager.createScript(context, name);
    this.reloadScripts();
    this.showNewScript = false;
    this.newScriptName = '';
    this.toast(`已创建 ${finalName}`);
  }

  private installBuiltin(idx: number): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const script = BUILTIN_SCRIPTS[idx];
    const ok = MpvConfigManager.installBuiltinScript(context, script);
    this.reloadScripts();
    this.toast(ok ? `已安装 ${script.name}` : `${script.name} 已存在`);
  }

  // ---------- script-opts ----------

  private openOptEditor(name: string): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.optName = name;
    this.optText = MpvConfigManager.readScriptOpt(context, name);
    this.showOptEditor = true;
  }

  private createOpt(): void {
    let name = this.optName.trim();
    if (name.length === 0) {
      this.toast('请输入配置名');
      return;
    }
    if (!name.endsWith('.conf')) {
      name = name + '.conf';
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    MpvConfigManager.writeScriptOpt(context, name, this.optText);
    this.reloadScripts();
    this.showOptEditor = false;
    this.toast(`已保存 ${name}`);
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
  optRow(name: string) {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.doc_plaintext'))
        .fontSize(20)
        .fontColor([$r('app.color.brand')])
      Text(name)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .onClick(() => this.openOptEditor(name))
      Text('删除')
        .fontSize(13)
        .fontColor($r('app.color.warning'))
        .padding(6)
        .onClick(() => {
          const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
          MpvConfigManager.deleteScriptOpt(context, name);
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
  scriptEditorSheet() {
    Column({ space: 12 }) {
      Text(this.editorTitle)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 4 })
      TextArea({ text: this.editorText, placeholder: '-- Lua 脚本内容' })
        .height(320)
        .fontSize(12)
        .fontFamily('monospace')
        .backgroundColor($r('app.color.input_background'))
        .fontColor($r('app.color.text_primary'))
        .borderRadius(12)
        .onChange((v: string) => {
          this.editorText = v;
        })
      Button('保存')
        .height(44)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .backgroundColor($r('app.color.brand'))
        .fontColor($r('app.color.text_on_brand'))
        .borderRadius(22)
        .margin({ bottom: 28 })
        .onClick(() => this.saveScriptEditor())
    }
    .width('100%')
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

  @Builder
  newScriptSheet() {
    Column({ space: 12 }) {
      Text('新建脚本')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 4 })
      TextInput({ text: this.newScriptName, placeholder: '脚本名（如 my-script）' })
        .height(48)
        .fontSize(16)
        .backgroundColor($r('app.color.input_background'))
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_tertiary'))
        .borderRadius(12)
        .onChange((v: string) => {
          this.newScriptName = v;
        })
      Button('创建')
        .height(44)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .backgroundColor($r('app.color.brand'))
        .fontColor($r('app.color.text_on_brand'))
        .borderRadius(22)
        .margin({ bottom: 28 })
        .onClick(() => this.createScript())
    }
    .width('100%')
    .padding({ left: 20, right: 20 })
  }

  @Builder
  optsSheet() {
    Column({ space: 8 }) {
      Text('脚本配置 (script-opts)')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 4, bottom: 4 })
      Scroll() {
        Column() {
          if (this.optsNames.length === 0) {
            Text('暂无脚本配置。脚本通过 mp.options 读取同名 .conf 文件。')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ top: 4, bottom: 4 })
          }
          ForEach(this.optsNames, (name: string) => {
            this.optRow(name)
          }, (name: string) => name)
        }
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      Button('新建配置')
        .height(44)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .backgroundColor($r('app.color.brand'))
        .fontColor($r('app.color.text_on_brand'))
        .borderRadius(22)
        .margin({ top: 8 })
        .onClick(() => {
          this.optName = '';
          this.optText = '';
          this.showOptEditor = true;
        })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, bottom: 24 })
  }

  @Builder
  optEditorSheet() {
    Column({ space: 12 }) {
      Text(this.optName.length > 0 ? this.optName : '新建脚本配置')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 4 })
      if (this.optName === '') {
        TextInput({ text: this.optName, placeholder: '配置名（如 autoload）' })
          .height(48)
          .fontSize(16)
          .backgroundColor($r('app.color.input_background'))
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_tertiary'))
          .borderRadius(12)
          .onChange((v: string) => {
            this.optName = v;
          })
      }
      TextArea({ text: this.optText, placeholder: '# key=value 格式' })
        .height(240)
        .fontSize(12)
        .fontFamily('monospace')
        .backgroundColor($r('app.color.input_background'))
        .fontColor($r('app.color.text_primary'))
        .borderRadius(12)
        .onChange((v: string) => {
          this.optText = v;
        })
      Button('保存')
        .height(44)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .backgroundColor($r('app.color.brand'))
        .fontColor($r('app.color.text_on_brand'))
        .borderRadius(22)
        .margin({ bottom: 28 })
        .onClick(() => this.createOpt())
    }
    .width('100%')
    .padding({ left: 20, right: 20 })
  }

  build() {
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

        // ===== 刮削 (TMDB) =====
        this.sectionTitle('刮削 (TMDB)')
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

          TextInput({ text: this.scrapeKey, placeholder: 'TMDB API Key（v3）' })
            .height(48)
            .fontSize(16)
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
          Text('支持 mpv 标准配置语法（音量、缓存、字幕样式、着色器等）。脚本消息 (script-message) 会透传到播放器界面。')
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
            Text('暂无脚本。可导入 .lua 文件、新建脚本或安装内置脚本。')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ top: 4, bottom: 4 })
          }
          ForEach(this.scripts, (script: ScriptEntry) => {
            this.scriptRow(script)
          }, (script: ScriptEntry) => `${script.name}-${script.enabled}`)

          Row({ space: 8 }) {
            Button('导入')
              .height(40)
              .fontSize(14)
              .layoutWeight(1)
              .backgroundColor($r('app.color.brand'))
              .fontColor($r('app.color.text_on_brand'))
              .borderRadius(20)
              .onClick(() => this.importScript())
            Button('新建')
              .height(40)
              .fontSize(14)
              .layoutWeight(1)
              .backgroundColor($r('app.color.brand_light'))
              .fontColor($r('app.color.brand'))
              .borderRadius(20)
              .onClick(() => {
                this.showNewScript = true;
              })
            Button('内置脚本')
              .height(40)
              .fontSize(14)
              .layoutWeight(1)
              .backgroundColor($r('app.color.brand_light'))
              .fontColor($r('app.color.brand'))
              .borderRadius(20)
              .onClick(() => {
                this.showBuiltin = true;
              })
            Button('脚本配置')
              .height(40)
              .fontSize(14)
              .layoutWeight(1)
              .backgroundColor($r('app.color.brand_light'))
              .fontColor($r('app.color.brand'))
              .borderRadius(20)
              .onClick(() => {
                this.showOpts = true;
              })
          }
          .width('100%')
          .margin({ top: 4 })

          Text(`脚本目录: ${this.scriptsDir}\n点击脚本名可查看/编辑内容；停用的脚本不会加载。`)
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .margin({ top: 4 })
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
      title: { title: '编辑脚本' },
    })
    .bindSheet($$this.showBuiltin, this.builtinSheet(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: true,
      backgroundColor: $r('app.color.card_background'),
      title: { title: '内置脚本' },
    })
    .bindSheet($$this.showNewScript, this.newScriptSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: true,
      backgroundColor: $r('app.color.card_background'),
      title: { title: '新建脚本' },
    })
    .bindSheet($$this.showOpts, this.optsSheet(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: true,
      backgroundColor: $r('app.color.card_background'),
      title: { title: '脚本配置' },
    })
    .bindSheet($$this.showOptEditor, this.optEditorSheet(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: true,
      backgroundColor: $r('app.color.card_background'),
      title: { title: '编辑配置' },
    })
  }
}
