/**
 * HPVPlayer - mpv 配置目录与 Lua 脚本管理。
 *
 * 沙箱布局（context.filesDir/mpv）:
 *   mpv.conf        用户可编辑的 mpv 配置（首次启动从 rawfile 释放）
 *   scripts/        Lua 脚本（*.lua 加载，*.lua.off 停用）
 *   script-opts/    脚本配置目录
 */
import { util } from '@kit.ArkTS';
import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';
import zlib from '@ohos.zlib';
import { picker } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;

export interface ScriptEntry {
  /** 展示名，如 autoload.lua */
  name: string;
  /** 完整沙箱路径 */
  path: string;
  enabled: boolean;
}

/** 配置文件管理器条目（相对 mpv 配置根） */
export interface ConfigFileEntry {
  name: string;
  /** 相对配置根路径（目录树用） */
  path: string;
  isDir: boolean;
  size: number;
  mtime: number;
}

/** 内置可一键安装的 Lua 脚本（mpv 官方 TOOLS/lua 精简版） */
export interface BuiltinScript {
  name: string;
  title: string;
  description: string;
  content: string;
}

export const BUILTIN_SCRIPTS: BuiltinScript[] = [
  {
    name: 'autoload.lua',
    title: '自动连播',
    description: '播放时自动把同目录其余媒体追加到播放列表（本地文件夹场景）',
    content: `-- HPVPlayer 内置: autoload（基于 mpv 官方 TOOLS/lua/autoload.lua 精简）
-- 播放本地文件时把同目录其它媒体文件追加进播放列表
local utils = require 'mp.utils'
local msg = require 'mp.msg'

local EXTENSIONS = {
    'mp4', 'mkv', 'avi', 'mov', 'flv', 'ts', 'm2ts', 'webm', 'wmv',
    'mpg', 'mpeg', '3gp', 'rm', 'rmvb', 'm4v', 'vob', 'ogv',
    'mp3', 'flac', 'wav', 'aac', 'ogg', 'opus', 'm4a', 'ape',
}
local PROTOCOLS = { 'http', 'https', 'dav' }

local function is_protocol(path)
    for _, p in ipairs(PROTOCOLS) do
        if path:find('^' .. p .. '://') then return true end
    end
    return false
end

local function has_extension(path)
    local ext = path:match('%.([^%.]+)$')
    if ext == nil then return false end
    ext = ext:lower()
    for _, e in ipairs(EXTENSIONS) do
        if ext == e then return true end
    end
    return false
end

local function add_files()
    local path = mp.get_property('path')
    if path == nil or is_protocol(path) then return end
    local dir = utils.split_path(path)
    if dir == nil then return end
    local files = utils.readdir(dir, 'files') or {}
    table.sort(files)
    local current = mp.get_property('filename')
    for _, name in ipairs(files) do
        local full = dir .. name
        if name ~= current and has_extension(name) then
            mp.commandv('loadfile', full, 'append')
        end
    end
    msg.info('autoload: playlist extended')
end

mp.register_event('file-loaded', add_files)
`,
  },
  {
    name: 'stats.lua',
    title: '播放统计',
    description: '统计播放时长与会话信息，输出到 OSD（script-message stats）',
    content: `-- HPVPlayer 内置: stats（简易会话统计）
-- 用法: 播放时通过 script-message stats 查看本次会话统计
local msg = require 'mp.msg'
local start_time = nil
local played_seconds = 0
local last_pos = 0

mp.register_event('file-loaded', function()
    if start_time == nil then start_time = os.time() end
    last_pos = 0
end)

mp.observe_property('time-pos', 'number', function(_, pos)
    if pos ~= nil and pos > last_pos and pos - last_pos < 2 then
        played_seconds = played_seconds + (pos - last_pos)
    end
    if pos ~= nil then last_pos = pos end
end)

mp.register_script_message('stats', function()
    local h = math.floor(played_seconds / 3600)
    local m = math.floor((played_seconds % 3600) / 60)
    local s = math.floor(played_seconds % 60)
    mp.osd_message(string.format('本次已看 %02d:%02d:%02d', h, m, s), 3)
    msg.info('session played: ' .. played_seconds .. 's')
end)
`,
  },
  {
    name: 'remember-position.lua',
    title: '记忆播放位置',
    description: '退出播放时把进度写入 script-opts，配合 watch-later 双保险',
    content: `-- HPVPlayer 内置: remember-position
-- 播放列表切换/结束时把进度写到 stdin 注释，供下次续播参考
local utils = require 'mp.utils'

mp.register_event('end-file', function(ev)
    local path = mp.get_property('path')
    local pos = mp.get_property_number('time-pos', 0)
    local dur = mp.get_property_number('duration', 0)
    if path == nil or dur <= 0 or ev.reason == 'eof' then return end
    -- mpv watch-later 已记录 start；此处补一条日志方便排查
    mp.msg.info(string.format('left at %d/%d (%.0f%%)',
        pos, dur, pos / dur * 100))
end)
`,
  },
];

export class MpvConfigManager {
  static readonly CONF_FILE = 'mpv.conf';
  static readonly RAWFILE_CONF = 'mpv/mpv.conf';
  static readonly SCRIPTS_DIR = 'scripts';
  static readonly SCRIPT_OPTS_DIR = 'script-opts';
  static readonly OFF_EXT = '.off';
  /** 内置弹幕脚本修订号：调整 rawfile/danmaku 内容时递增，触发已安装旧版自动替换 */
  static readonly DANMAKU_REV = '5';
  static readonly DANMAKU_REV_FILE = '.hpv-rev';

  /**
   * 确保 mpv 配置目录结构就绪，返回 configDir（传入 PlayerConfig）。
   */
  static ensureConfigDir(context: common.UIAbilityContext): string {
    const dir = context.filesDir + '/mpv';
    MpvConfigManager.ensureDir(dir);
    MpvConfigManager.ensureDir(dir + '/' + MpvConfigManager.SCRIPTS_DIR);
    MpvConfigManager.ensureDir(dir + '/' + MpvConfigManager.SCRIPT_OPTS_DIR);
    const conf = dir + '/' + MpvConfigManager.CONF_FILE;
    if (!fs.accessSync(conf)) {
      const raw = context.resourceManager.getRawFileContentSync(MpvConfigManager.RAWFILE_CONF);
      const file = fs.openSync(conf, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      try {
        fs.writeSync(file.fd, raw);
      } finally {
        fs.closeSync(file);
      }
    }
    return dir;
  }

  /** configDir（不创建） */
  static configDir(context: common.UIAbilityContext): string {
    return context.filesDir + '/mpv';
  }

  // ---------- 导出 / 导入（用户在文件管理器中手动编辑配置的桥梁） ----------

  /**
   * 安装/升级内置弹幕脚本（rawfile/danmaku → scripts/danmaku/，递归释放）。
   *
   * 版本策略见 danmakuNeedsUpgrade：目标目录带 .hpv-rev 标记且不低于内置修订号 → 跳过；
   * 其余（标记落后，或无标记但形如 uosc_danmaku 的旧内置安装）→ 整目录替换升级。
   * 用户数据（script-opts/danmaku.conf、~~/danmaku-history.json）不在该目录内，替换无副作用。
   * @returns true 本次实际安装/升级；false 已是最新
   */
  static installDanmaku(context: common.UIAbilityContext): boolean {
    let target = MpvConfigManager.configDir(context) + '/scripts/danmaku';
    // 用户在设置里停用过（danmaku.off）：原位升级但保持停用状态
    const offTarget = target + MpvConfigManager.OFF_EXT;
    if (!fs.accessSync(target) && fs.accessSync(offTarget)) {
      target = offTarget;
    }
    if (fs.accessSync(target)) {
      if (!MpvConfigManager.danmakuNeedsUpgrade(target)) {
        hilog.info(DOMAIN, 'HPVPlayer', 'installDanmaku: up-to-date, skip');
        return false;
      }
      hilog.info(DOMAIN, 'HPVPlayer', 'installDanmaku: upgrading, replace dir');
      MpvConfigManager.removeDirRecursive(target);
    }
    MpvConfigManager.ensureDir(target);
    const files: string[] = [];
    const dirs: string[] = [];
    MpvConfigManager.listRawfileTree(context, 'danmaku', '', dirs, files);
    for (const dir of dirs) {
      MpvConfigManager.ensureDir(target + '/' + dir);
    }
    let copied = 0;
    for (const file of files) {
      const raw = context.resourceManager.getRawFileContentSync(`danmaku/${file}`);
      const text = util.TextDecoder.create('utf-8').decodeToString(raw);
      MpvConfigManager.copyTextTo(text, target + '/' + file);
      copied++;
    }
    MpvConfigManager.copyTextTo(MpvConfigManager.DANMAKU_REV, target + '/' + MpvConfigManager.DANMAKU_REV_FILE);
    hilog.info(DOMAIN, 'HPVPlayer', 'installDanmaku: installed rev=%{public}s dirs=%{public}d files=%{public}d',
      MpvConfigManager.DANMAKU_REV, dirs.length, copied);
    return true;
  }

  /**
   * 已安装的内置弹幕脚本是否需要升级到内置修订号。
   * 有 .hpv-rev 标记：按修订号比较；
   * 无标记：目录结构形如 uosc_danmaku（main.lua + modules/utils.lua）即视为
   * 加桥之前安装的旧内置版本（早期构建无指纹无标记），强制替换。
   * （"danmaku" 目录名归 App 内置脚本所有；用户自定义导入请用其它目录名）
   */
  private static danmakuNeedsUpgrade(target: string): boolean {
    const revPath = target + '/' + MpvConfigManager.DANMAKU_REV_FILE;
    if (fs.accessSync(revPath)) {
      try {
        const installed = Number(fs.readTextSync(revPath).trim());
        return Number.isNaN(installed) ||
          installed < Number(MpvConfigManager.DANMAKU_REV);
      } catch (err) {
        return true;
      }
    }
    try {
      return fs.accessSync(target + '/main.lua') &&
        fs.accessSync(target + '/modules/utils.lua');
    } catch (err) {
      return false;
    }
  }

  /** 内置弹幕脚本是否已安装（含用户停用的 .off 目录） */
  static hasDanmaku(context: common.UIAbilityContext): boolean {
    const base = MpvConfigManager.configDir(context) + '/scripts/danmaku';
    return fs.accessSync(base + '/main.lua') ||
      fs.accessSync(base + MpvConfigManager.OFF_EXT + '/main.lua');
  }

  /**
   * 插件内化策略：scripts/ 只允许应用内置的脚本运行。
   * 白名单 = danmaku 弹幕包 + BUILTIN_SCRIPTS；其余（历史版本导入的外来脚本）
   * 统一改名 .off —— 保留在设备上但 mpv 不再加载，不删用户数据。
   * @returns 本次停用的外来脚本数
   */
  static enforceInternalScripts(context: common.UIAbilityContext): number {
    const dir = MpvConfigManager.configDir(context) + '/' + MpvConfigManager.SCRIPTS_DIR;
    if (!fs.accessSync(dir)) {
      return 0;
    }
    let disabled = 0;
    const names = fs.listFileSync(dir);
    for (const name of names) {
      if (name.startsWith('.') || name.startsWith('._')) {
        continue;
      }
      let base = name;
      if (base.endsWith(MpvConfigManager.OFF_EXT)) {
        base = base.substring(0, base.length - MpvConfigManager.OFF_EXT.length);
      }
      const stem = base.endsWith('.lua') ? base.substring(0, base.length - 4) : base;
      const builtin = stem === 'danmaku' ||
        BUILTIN_SCRIPTS.some((s: BuiltinScript): boolean => s.name === `${stem}.lua`);
      if (builtin) {
        continue;
      }
      const path = dir + '/' + name;
      if (!name.endsWith(MpvConfigManager.OFF_EXT)) {
        try {
          fs.renameSync(path, path + MpvConfigManager.OFF_EXT);
          disabled++;
          hilog.info(DOMAIN, 'HPVPlayer', 'enforceInternalScripts: disabled %{public}s', name);
        } catch (err) {
          hilog.warn(DOMAIN, 'HPVPlayer', 'disable foreign script failed: %{public}s', name);
        }
      }
    }
    return disabled;
  }

  /** 枚举 rawfile 目录树（递归） */
  private static listRawfileTree(context: common.UIAbilityContext, root: string,
    rel: string, dirs: string[], files: string[]): void {
    const path = rel.length > 0 ? `${root}/${rel}` : root;
    const names = context.resourceManager.getRawFileListSync(path);
    for (const name of names) {
      const childRel = rel.length > 0 ? `${rel}/${name}` : name;
      let isDir = false;
      try {
        // 尝试按目录枚举，成功即目录
        context.resourceManager.getRawFileListSync(`${path}/${name}`);
        isDir = true;
      } catch (err) {
        isDir = false;
      }
      if (isDir) {
        dirs.push(childRel);
        MpvConfigManager.listRawfileTree(context, root, childRel, dirs, files);
      } else {
        files.push(childRel);
      }
    }
  }
  /**
   * 导出：把整个 mpv 配置目录（mpv.conf + scripts/ + script-opts/）
   * 压缩为 zip，通过系统保存选择器让用户存到文件管理器任意位置。
   * @returns 保存成功返回 true（用户取消返回 false）
   */
  static async exportConfig(context: common.UIAbilityContext): Promise<boolean> {
    // 1. 先压缩到沙箱缓存
    const configDir = MpvConfigManager.configDir(context);
    MpvConfigManager.ensureDir(configDir);
    const tempZip = context.cacheDir + '/hpvplayer-mpv-config.zip';
    if (fs.accessSync(tempZip)) {
      fs.unlinkSync(tempZip);
    }
    await zlib.compressFile(configDir, tempZip, {
      level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION,
    });

    // 2. 拉起保存选择器，用户选目标位置
    const docSave = new picker.DocumentViewPicker(context);
    const saved: string[] = await docSave.save({
      newFileNames: [`hpvplayer-mpv-config-${Date.now()}.zip`],
      fileSuffixChoices: ['.zip'],
    });
    if (saved.length === 0) {
      return false; // 用户取消
    }

    // 3. 复制到用户选择的位置（URI 可写）
    const text = MpvConfigManager.readBinary(tempZip);
    const target = fs.openSync(saved[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(target.fd, text.buffer);
    } finally {
      fs.closeSync(target);
      fs.unlinkSync(tempZip);
    }
    return true;
  }

  /**
   * 导入：用户选择之前导出的 zip（可在文件管理器中编辑过内容），
   * 解压覆盖沙箱 mpv 配置目录。
   * @returns 导入的文件数（用户取消返回 -1）
   */
  static async importConfig(context: common.UIAbilityContext): Promise<number> {
    const docPick = new picker.DocumentViewPicker(context);
    const picked: string[] = await docPick.select({
      fileSuffixFilters: ['.zip'],
      maxSelectNumber: 1,
    });
    if (picked.length === 0) {
      return -1;
    }

    // 复制到沙箱缓存再解压（picker URI 无法直接作为 zlib 输入）
    const srcBytes = MpvConfigManager.readBinaryUri(picked[0]);
    const tempZip = context.cacheDir + '/hpvplayer-import.zip';
    const tmp = fs.openSync(tempZip, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(tmp.fd, srcBytes.buffer);
    } finally {
      fs.closeSync(tmp);
    }

    // 解压到临时目录，校验结构（应为 mpv/ 或直接含 mpv.conf）
    const tempDir = context.cacheDir + '/hpvplayer-import';
    MpvConfigManager.removeDirRecursive(tempDir);
    MpvConfigManager.ensureDir(tempDir);
    await zlib.decompressFile(tempZip, tempDir);

    // 定位配置根：tempDir/mpv/... 或 tempDir/ 直接含 mpv.conf
    let configRoot = tempDir;
    if (!fs.accessSync(tempDir + '/' + MpvConfigManager.CONF_FILE)) {
      const names = fs.listFileSync(tempDir);
      for (const name of names) {
        const child = tempDir + '/' + name;
        let isDir = false;
        try {
          isDir = fs.statSync(child).isDirectory();
        } catch (err) {
          isDir = false;
        }
        if (isDir && fs.accessSync(child + '/' + MpvConfigManager.CONF_FILE)) {
          configRoot = child;
          break;
        }
      }
    }
    if (!fs.accessSync(configRoot + '/' + MpvConfigManager.CONF_FILE)) {
      MpvConfigManager.removeDirRecursive(tempDir);
      fs.unlinkSync(tempZip);
      throw new Error('压缩包中没有找到 mpv.conf（应为应用导出的配置包）');
    }

    // 只导入配置数据（mpv.conf + script-opts/*.conf）。
    // 插件已内化：压缩包里的 scripts/ 一律忽略，也不清空沙箱 scripts/ 目录。
    const configDir = MpvConfigManager.configDir(context);
    let count = 0;
    const rootConf = configRoot + '/' + MpvConfigManager.CONF_FILE;
    MpvConfigManager.copyFileTo(rootConf, configDir + '/' + MpvConfigManager.CONF_FILE);
    count++;
    const optsRoot = configRoot + '/' + MpvConfigManager.SCRIPT_OPTS_DIR;
    if (fs.accessSync(optsRoot)) {
      for (const name of fs.listFileSync(optsRoot)) {
        if (name.startsWith('.') || name.startsWith('._') || !name.endsWith('.conf')) {
          continue;
        }
        MpvConfigManager.copyFileTo(optsRoot + '/' + name,
          configDir + '/' + MpvConfigManager.SCRIPT_OPTS_DIR + '/' + name);
        count++;
      }
    }
    MpvConfigManager.removeDirRecursive(tempDir);
    fs.unlinkSync(tempZip);
    return count;
  }

  /** 读二进制文件（沙箱路径） */
  private static readBinary(path: string): Uint8Array {
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const stat = fs.statSync(path);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      return new Uint8Array(buf);
    } finally {
      fs.closeSync(file);
    }
  }

  // ---------- 配置文件管理器（目录树浏览/编辑） ----------

  /** 文件管理器条目 */
  static makeFileEntry(name: string, path: string, isDir: boolean, size: number,
    mtime: number): ConfigFileEntry {
    return { name: name, path: path, isDir: isDir, size: size, mtime: mtime };
  }

  /** 列出目录（相对 mpv 配置根），目录在前、按名排序 */
  static listConfigDir(context: common.UIAbilityContext,
    relDir: string): ConfigFileEntry[] {
    const dir = MpvConfigManager.configDir(context) +
      (relDir.length > 0 ? '/' + relDir : '');
    if (!fs.accessSync(dir)) {
      return [];
    }
    const entries: ConfigFileEntry[] = [];
    for (const name of fs.listFileSync(dir).sort()) {
      if (name.startsWith('.') || name.startsWith('._')) {
        continue;
      }
      const path = dir + '/' + name;
      let isDir = false;
      let size = 0;
      let mtime = 0;
      try {
        const stat = fs.statSync(path);
        isDir = stat.isDirectory();
        size = stat.size;
        mtime = stat.mtime;
      } catch (err) {
        // 无权限等，跳过
        continue;
      }
      const rel = relDir.length > 0 ? `${relDir}/${name}` : name;
      entries.push(MpvConfigManager.makeFileEntry(name, rel, isDir, size, mtime));
    }
    // 目录在前
    entries.sort((a: ConfigFileEntry, b: ConfigFileEntry) => {
      if (a.isDir !== b.isDir) {
        return a.isDir ? -1 : 1;
      }
      return a.name.localeCompare(b.name);
    });
    return entries;
  }

  /** 读文本文件（相对配置根） */
  static readConfigFile(context: common.UIAbilityContext, relPath: string): string {
    return MpvConfigManager.readFileText(
      MpvConfigManager.configDir(context) + '/' + relPath);
  }

  /**
   * 插件内化守卫：scripts/ 由应用内置脚本独占（版本化安装管理），
   * 配置浏览器不可写入/新建/改名/删除，防止篡改或绕道注入外来脚本。
   */
  private static assertNotScripts(relPath: string): void {
    const first = relPath.split('/')[0];
    if (first === MpvConfigManager.SCRIPTS_DIR) {
      throw new Error('插件已内化：scripts/ 由应用统一管理，不可在此修改');
    }
  }

  /** 写文本文件（相对配置根），自动创建父目录 */
  static writeConfigFile(context: common.UIAbilityContext, relPath: string,
    text: string): void {
    MpvConfigManager.assertNotScripts(relPath);
    MpvConfigManager.copyTextTo(text,
      MpvConfigManager.configDir(context) + '/' + relPath);
  }

  /** 新建文件或目录（相对配置根）；重名自动加序号，返回最终相对路径 */
  static createConfigEntry(context: common.UIAbilityContext, relDir: string,
    name: string, asDir: boolean): string {
    MpvConfigManager.assertNotScripts(relDir.length > 0 ? `${relDir}/${name}` : name);
    const dir = MpvConfigManager.configDir(context) +
      (relDir.length > 0 ? '/' + relDir : '');
    MpvConfigManager.ensureDir(dir);
    let target = dir + '/' + name;
    let seq = 1;
    const dot = asDir ? -1 : name.lastIndexOf('.');
    const base = dot > 0 ? name.substring(0, dot) : name;
    const ext = dot > 0 ? name.substring(dot) : '';
    while (fs.accessSync(target)) {
      target = dir + '/' + base + '-' + seq + ext;
      seq++;
    }
    if (asDir) {
      fs.mkdirSync(target, true);
    } else {
      const file = fs.openSync(target, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      fs.closeSync(file);
    }
    const finalName = target.substring(target.lastIndexOf('/') + 1);
    return relDir.length > 0 ? `${relDir}/${finalName}` : finalName;
  }

  /** 重命名（相对配置根），返回新相对路径 */
  static renameConfigEntry(context: common.UIAbilityContext, relPath: string,
    newName: string): string {
    MpvConfigManager.assertNotScripts(relPath);
    const abs = MpvConfigManager.configDir(context) + '/' + relPath;
    const parent = relPath.substring(0, relPath.lastIndexOf('/'));
    const dir = MpvConfigManager.configDir(context) + (parent.length > 0 ? '/' + parent : '');
    let target = dir + '/' + newName;
    let seq = 1;
    while (fs.accessSync(target)) {
      target = dir + '/' + newName + '-' + seq;
      seq++;
    }
    fs.renameSync(abs, target);
    const finalName = target.substring(target.lastIndexOf('/') + 1);
    return parent.length > 0 ? `${parent}/${finalName}` : finalName;
  }

  /** 删除（相对配置根），目录递归删除 */
  static deleteConfigEntry(context: common.UIAbilityContext, relPath: string): void {
    MpvConfigManager.assertNotScripts(relPath);
    const abs = MpvConfigManager.configDir(context) + '/' + relPath;
    let isDir = false;
    try {
      isDir = fs.statSync(abs).isDirectory();
    } catch (err) {
      isDir = false;
    }
    if (isDir) {
      MpvConfigManager.removeDirRecursive(abs);
    } else {
      fs.unlinkSync(abs);
    }
  }

  /** 读文本文件（支持 file://docs URI 与沙箱路径） */
  static readUriText(uri: string): string {
    let path = uri;
    if (uri.startsWith('file://')) {
      const idx = uri.indexOf('://');
      let rest = uri.substring(idx + 3);
      if (rest.startsWith('docs/')) {
        rest = rest.substring('docs'.length);
      }
      try {
        path = decodeURIComponent(rest);
      } catch (err) {
        path = rest;
      }
    }
    try {
      return MpvConfigManager.readFileText(path);
    } catch (err) {
      return '';
    }
  }

  /** 文本复制到沙箱目标路径（自动建父目录） */
  private static copyTextTo(text: string, destPath: string): void {
    const destDir = destPath.substring(0, destPath.lastIndexOf('/'));
    MpvConfigManager.ensureDir(destDir);
    const file = fs.openSync(destPath,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
  }

  /** 读二进制文件（支持 file://docs URI 与沙箱路径） */
  private static readBinaryUri(uri: string): Uint8Array {
    let path = uri;
    if (uri.startsWith('file://')) {
      const idx = uri.indexOf('://');
      let rest = uri.substring(idx + 3);
      if (rest.startsWith('docs/')) {
        rest = rest.substring('docs'.length);
      }
      try {
        path = decodeURIComponent(rest);
      } catch (err) {
        path = rest;
      }
    }
    return MpvConfigManager.readBinary(path);
  }

  static readConf(context: common.UIAbilityContext): string {
    const conf = MpvConfigManager.configDir(context) + '/' + MpvConfigManager.CONF_FILE;
    return MpvConfigManager.readFileText(conf);
  }

  static saveConf(context: common.UIAbilityContext, text: string): void {
    const conf = MpvConfigManager.configDir(context) + '/' + MpvConfigManager.CONF_FILE;
    const file = fs.openSync(conf, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
  }

  /** 恢复默认 mpv.conf，返回默认内容 */
  static resetConf(context: common.UIAbilityContext): string {
    const raw = context.resourceManager.getRawFileContentSync(MpvConfigManager.RAWFILE_CONF);
    const text = util.TextDecoder.create('utf-8').decodeToString(raw);
    MpvConfigManager.saveConf(context, text);
    return text;
  }

  /** 列出 scripts 目录下的 Lua 脚本（单文件 + 脚本包目录，含停用的） */
  static listScripts(context: common.UIAbilityContext): ScriptEntry[] {
    const dir = MpvConfigManager.configDir(context) + '/' + MpvConfigManager.SCRIPTS_DIR;
    if (!fs.accessSync(dir)) {
      return [];
    }
    const entries: ScriptEntry[] = [];
    const names = fs.listFileSync(dir).sort();
    for (const name of names) {
      if (name.startsWith('.') || name.startsWith('._')) {
        continue;
      }
      const path = dir + '/' + name;
      let isDir = false;
      try {
        isDir = fs.statSync(path).isDirectory();
      } catch (err) {
        isDir = false;
      }
      if (isDir) {
        // 脚本包目录：剥 .off 后缀识别停用状态，目录内有 .lua 才算
        let pkgName = name;
        let pkgEnabled = true;
        if (name.endsWith(MpvConfigManager.OFF_EXT)) {
          pkgName = name.substring(0, name.length - MpvConfigManager.OFF_EXT.length);
          pkgEnabled = false;
        }
        if (MpvConfigManager.dirHasLua(path)) {
          entries.push({ name: pkgName + '/', path: path, enabled: pkgEnabled });
        }
        continue;
      }
      if (name.endsWith('.lua')) {
        entries.push({ name: name, path: path, enabled: true });
      } else if (name.endsWith('.lua' + MpvConfigManager.OFF_EXT)) {
        entries.push({
          name: name.substring(0, name.length - MpvConfigManager.OFF_EXT.length),
          path: path,
          enabled: false,
        });
      }
    }
    return entries;
  }

  private static dirHasLua(dir: string): boolean {
    const stack: string[] = [dir];
    while (stack.length > 0) {
      const cur = stack.pop()!;
      let names: string[] = [];
      try {
        names = fs.listFileSync(cur);
      } catch (err) {
        continue;
      }
      for (const name of names) {
        if (name.startsWith('.') || name.startsWith('._')) {
          continue;
        }
        const child = cur + '/' + name;
        let isDir = false;
        try {
          isDir = fs.statSync(child).isDirectory();
        } catch (err) {
          isDir = false;
        }
        if (isDir) {
          stack.push(child);
        } else if (name.endsWith('.lua') || name.endsWith('.lua' + MpvConfigManager.OFF_EXT)) {
          return true;
        }
      }
    }
    return false;
  }

  /** 启用/停用脚本（单文件切 .lua <-> .lua.off；脚本包目录切 目录名 <-> 目录名.off） */
  static toggleScript(entry: ScriptEntry, enable: boolean): void {
    const dir = entry.path.substring(0, entry.path.lastIndexOf('/'));
    const isDir = entry.name.endsWith('/');
    // 统一从展示名取原始名（已剥掉 .off 和目录斜杠）
    const baseName = isDir ? entry.name.substring(0, entry.name.length - 1) : entry.name;
    const suffix = isDir ? '' : '.lua';
    const target = enable ?
      dir + '/' + baseName + suffix :
      dir + '/' + baseName + suffix + MpvConfigManager.OFF_EXT;
    if (entry.path !== target) {
      fs.renameSync(entry.path, target);
    }
  }

  static deleteScript(entry: ScriptEntry): void {
    let isDir = false;
    try {
      isDir = fs.statSync(entry.path).isDirectory();
    } catch (err) {
      isDir = false;
    }
    if (isDir) {
      MpvConfigManager.removeDirRecursive(entry.path);
    } else {
      fs.unlinkSync(entry.path);
    }
  }

  private static removeDirRecursive(dir: string): void {
    let names: string[] = [];
    try {
      names = fs.listFileSync(dir);
    } catch (err) {
      return;
    }
    for (const name of names) {
      const child = dir + '/' + name;
      let childIsDir = false;
      try {
        childIsDir = fs.statSync(child).isDirectory();
      } catch (err) {
        childIsDir = false;
      }
      if (childIsDir) {
        MpvConfigManager.removeDirRecursive(child);
      } else {
        try {
          fs.unlinkSync(child);
        } catch (err) {
          // 忽略单项失败
        }
      }
    }
    try {
      fs.rmdirSync(dir);
    } catch (err) {
      // 忽略
    }
  }

  /** 读取脚本内容（脚本包目录 → 读与目录同名的入口 .lua，否则读第一个 .lua）。只读诊断用。 */
  static readScript(entry: ScriptEntry): string {
    if (entry.name.endsWith('/')) {
      const entryFile = MpvConfigManager.findEntryLua(entry.path, entry.name);
      if (entryFile !== '') {
        return MpvConfigManager.readFileText(entryFile);
      }
      return '';
    }
    return MpvConfigManager.readFileText(entry.path);
  }

  /** 找脚本包入口：优先 <目录名>.lua，否则按序第一个 .lua */
  private static findEntryLua(dir: string, displayName: string): string {
    const dirName = displayName.endsWith('/') ?
      displayName.substring(0, displayName.length - 1) : displayName;
    const stack: string[] = [dir];
    let firstLua = '';
    while (stack.length > 0) {
      const cur = stack.pop()!;
      let names: string[] = [];
      try {
        names = fs.listFileSync(cur);
      } catch (err) {
        continue;
      }
      for (const name of names.sort()) {
        if (name.startsWith('.') || name.startsWith('._')) {
          continue;
        }
        const child = cur + '/' + name;
        let isDir = false;
        try {
          isDir = fs.statSync(child).isDirectory();
        } catch (err) {
          isDir = false;
        }
        if (isDir) {
          stack.push(child);
        } else if (name === `${dirName}.lua`) {
          return child; // 与目录同名的入口最优先
        } else if (firstLua === '' && name.endsWith('.lua')) {
          firstLua = child;
        }
      }
    }
    return firstLua;
  }

  /** 重命名脚本（保持启用状态），返回新脚本名 */
  static renameScript(entry: ScriptEntry, newName: string): string {
    const dir = entry.path.substring(0, entry.path.lastIndexOf('/'));
    let name = newName;
    if (!name.toLowerCase().endsWith('.lua')) {
      name = name + '.lua';
    }
    const off = entry.enabled ? '' : MpvConfigManager.OFF_EXT;
    const target = dir + '/' + name + off;
    if (entry.path !== target) {
      fs.renameSync(entry.path, target);
    }
    return name;
  }

  /** 一键安装内置脚本；已存在同名脚本时返回 false */
  static installBuiltinScript(context: common.UIAbilityContext, script: BuiltinScript): boolean {
    const dir = MpvConfigManager.configDir(context) + '/' + MpvConfigManager.SCRIPTS_DIR;
    MpvConfigManager.ensureDir(dir);
    if (fs.accessSync(dir + '/' + script.name)) {
      return false;
    }
    const file = fs.openSync(dir + '/' + script.name,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, script.content);
    } finally {
      fs.closeSync(file);
    }
    return true;
  }

  // ---------- script-opts（脚本配置） ----------

  /** 列出 script-opts 目录下的 .conf 文件名 */
  static listScriptOpts(context: common.UIAbilityContext): string[] {
    const dir = MpvConfigManager.configDir(context) + '/' + MpvConfigManager.SCRIPT_OPTS_DIR;
    if (!fs.accessSync(dir)) {
      return [];
    }
    return fs.listFileSync(dir)
      .filter((name: string) => name.endsWith('.conf'))
      .sort();
  }

  static readScriptOpt(context: common.UIAbilityContext, name: string): string {
    const file = MpvConfigManager.configDir(context) + '/' +
      MpvConfigManager.SCRIPT_OPTS_DIR + '/' + name;
    return MpvConfigManager.readFileText(file);
  }

  static writeScriptOpt(context: common.UIAbilityContext, name: string, text: string): void {
    const dir = MpvConfigManager.configDir(context) + '/' + MpvConfigManager.SCRIPT_OPTS_DIR;
    MpvConfigManager.ensureDir(dir);
    const file = fs.openSync(dir + '/' + name,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
  }

  static deleteScriptOpt(context: common.UIAbilityContext, name: string): void {
    const file = MpvConfigManager.configDir(context) + '/' +
      MpvConfigManager.SCRIPT_OPTS_DIR + '/' + name;
    if (fs.accessSync(file)) {
      fs.unlinkSync(file);
    }
  }

  private static copyFileTo(srcPath: string, destPath: string): void {
    const destDir = destPath.substring(0, destPath.lastIndexOf('/'));
    MpvConfigManager.ensureDir(destDir);
    const text = MpvConfigManager.readFileText(srcPath);
    const file = fs.openSync(destPath,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
  }

  private static ensureDir(dir: string): void {
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
  }

  private static readFileText(path: string): string {
    if (!fs.accessSync(path)) {
      return '';
    }
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const stat = fs.statSync(path);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
    } finally {
      fs.closeSync(file);
    }
  }
}
