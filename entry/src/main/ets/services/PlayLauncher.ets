/**
 * HPVPlayer - 播放启动入口：写最近播放 + 跳转播放页。
 * 播放器是独立 router 全屏页（沉浸式），不进 Navigation 栈。
 */
import { router } from '@kit.ArkUI';
import { PlayItem, PlayKind, PlayRequest } from '../models/PlayItem';
import { SettingsStore } from './SettingsStore';

export class PlayLauncher {
  static async play(items: PlayItem[], index: number = 0, kind: PlayKind = 'url'): Promise<void> {
    if (items.length === 0) {
      return;
    }
    const current = items[Math.min(index, items.length - 1)];
    const title = current.title.length > 0 ?
      current.title : PlayLauncher.baseName(current.uri);
    SettingsStore.addRecent({
      title: title,
      uri: current.uri,
      headers: current.headers,
      kind: kind,
      ts: Date.now(),
    });
    const request: PlayRequest = { items: items, index: index, kind: kind };
    router.pushUrl({
      url: 'pages/PlayerPage',
      params: request as object as Record<string, Object>,
    });
  }

  static baseName(uri: string): string {
    let path = uri.split('?')[0];
    const slash = path.lastIndexOf('/');
    path = slash >= 0 ? path.substring(slash + 1) : path;
    try {
      return decodeURIComponent(path);
    } catch (err) {
      return path;
    }
  }
}
