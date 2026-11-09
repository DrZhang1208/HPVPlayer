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

export interface ScriptEntry {
  /** 展示名，如 autoload.lua */
  name: string;
  /** 完整沙箱路径 */
  path: string;
  enabled: boolean;
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

  /** 列出 scripts 目录下的 Lua 脚本（含停用的） */
  static listScripts(context: common.UIAbilityContext): ScriptEntry[] {
    const dir = MpvConfigManager.configDir(context) + '/' + MpvConfigManager.SCRIPTS_DIR;
    if (!fs.accessSync(dir)) {
      return [];
    }
    const entries: ScriptEntry[] = [];
    const names = fs.listFileSync(dir).sort();
    for (const name of names) {
      if (name.endsWith('.lua')) {
        entries.push({ name: name, path: dir + '/' + name, enabled: true });
      } else if (name.endsWith('.lua' + MpvConfigManager.OFF_EXT)) {
        entries.push({
          name: name.substring(0, name.length - MpvConfigManager.OFF_EXT.length),
          path: dir + '/' + name,
          enabled: false,
        });
      }
    }
    return entries;
  }

  /** 启用/停用脚本（切换 .lua <-> .lua.off） */
  static toggleScript(entry: ScriptEntry, enable: boolean): void {
    const dir = entry.path.substring(0, entry.path.lastIndexOf('/'));
    const target = enable ?
      dir + '/' + entry.name :
      dir + '/' + entry.name + MpvConfigManager.OFF_EXT;
    if (entry.path !== target) {
      fs.renameSync(entry.path, target);
    }
  }

  static deleteScript(entry: ScriptEntry): void {
    fs.unlinkSync(entry.path);
  }

  /** 读取脚本内容 */
  static readScript(entry: ScriptEntry): string {
    return MpvConfigManager.readFileText(entry.path);
  }

  /** 覆写脚本内容 */
  static writeScript(entry: ScriptEntry, text: string): void {
    const file = fs.openSync(entry.path,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
  }

  /** 新建空白脚本，返回最终脚本名（重名自动加序号） */
  static createScript(context: common.UIAbilityContext, displayName: string): string {
    return MpvConfigManager.importScript(context, '', displayName);
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

  /**
   * 从文件选择器 URI 导入脚本到 scripts/ 目录。
   * @returns 导入后的脚本名
   */
  static importScript(context: common.UIAbilityContext, uri: string, displayName: string): string {
    let name = displayName;
    if (!name.toLowerCase().endsWith('.lua')) {
      name = name + '.lua';
    }
    const dir = MpvConfigManager.configDir(context) + '/' + MpvConfigManager.SCRIPTS_DIR;
    MpvConfigManager.ensureDir(dir);
    // 重名时加序号
    let target = dir + '/' + name;
    if (fs.accessSync(target)) {
      const dot = name.lastIndexOf('.');
      const base = dot > 0 ? name.substring(0, dot) : name;
      let seq = 1;
      while (fs.accessSync(target)) {
        target = dir + '/' + base + '-' + seq + '.lua';
        seq++;
      }
    }
    let text = '';
    if (uri.length > 0) {
      text = MpvConfigManager.readFileText(uri);
    }
    const file = fs.openSync(target, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
    return target.substring(target.lastIndexOf('/') + 1);
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
