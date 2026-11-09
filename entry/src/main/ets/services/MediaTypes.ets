/**
 * HPVPlayer - 媒体文件类型判定。
 */

const VIDEO_EXTS: string[] = [
  'mp4', 'mkv', 'avi', 'mov', 'flv', 'ts', 'm2ts', 'webm', 'wmv', 'mpg', 'mpeg',
  'm2v', '3gp', 'rm', 'rmvb', 'm4v', 'vob', 'ogv', 'asf', 'divx', 'f4v', 'mts', 'iso',
];

const AUDIO_EXTS: string[] = [
  'mp3', 'flac', 'wav', 'aac', 'ogg', 'opus', 'm4a', 'ape', 'wv', 'aiff', 'alac',
];

const PLAYLIST_EXTS: string[] = ['m3u', 'm3u8'];

export const SUBTITLE_EXTS: string[] = ['srt', 'ass', 'ssa', 'vtt', 'sub', 'idx', 'sup', 'pjb', 'ttml', 'lrc'];

export class MediaTypes {
  static extOf(name: string): string {
    const dot = name.lastIndexOf('.');
    if (dot < 0 || dot === name.length - 1) {
      return '';
    }
    return name.substring(dot + 1).toLowerCase();
  }

  static isVideo(name: string): boolean {
    return VIDEO_EXTS.includes(MediaTypes.extOf(name));
  }

  static isAudio(name: string): boolean {
    return AUDIO_EXTS.includes(MediaTypes.extOf(name));
  }

  static isMedia(name: string): boolean {
    return MediaTypes.isVideo(name) || MediaTypes.isAudio(name);
  }

  static isPlaylist(name: string): boolean {
    return PLAYLIST_EXTS.includes(MediaTypes.extOf(name));
  }

  static isSubtitle(name: string): boolean {
    return SUBTITLE_EXTS.includes(MediaTypes.extOf(name));
  }

  /** 人类可读的大小 */
  static formatSize(size: number): string {
    if (size <= 0) {
      return '';
    }
    if (size < 1024) {
      return `${size} B`;
    }
    if (size < 1024 * 1024) {
      return `${(size / 1024).toFixed(1)} KB`;
    }
    if (size < 1024 * 1024 * 1024) {
      return `${(size / 1024 / 1024).toFixed(1)} MB`;
    }
    return `${(size / 1024 / 1024 / 1024).toFixed(2)} GB`;
  }
}
