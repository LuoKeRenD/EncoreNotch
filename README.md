# EncoreNotch

把 MacBook 的刘海变成一座「灵动岛」：显示正在播放的音乐和同步歌词，暂存拖进来的文件，并实时显示 Claude Code 会话，还能直接在刘海里批准权限请求、回答 Claude 的提问。

> EncoreNotch 修改自 TheBoredTeam 的 [Boring Notch](https://github.com/TheBoredTeam/boring.notch)，以 GPL-3.0 许可证发布。
> 自 2026-11-08 起的修改：删除了日历、镜子、系统 HUD 替换、电池指示、媒体键拦截、XPC 辅助程序、Sparkle 自动更新和手势控制；新增了同步歌词、歌词窗口、Claude Code 会话监控和 Clawd 动画。

## 功能

### 音乐与歌词
- 支持 Now Playing（所有媒体 App）、Apple Music、Spotify 和 YouTube Music。
- 从 [LRCLIB](https://lrclib.net) 获取同步歌词，支持逐字时间轴，查询结果缓存在本地。
- 刘海里显示上一句、当前句和下一句；也可以在收起的刘海下方显示当前这一句。
- 点击歌词跳转到对应位置；歌词偏移可以整体调整，也可以每首歌单独调整。
- 歌词窗口使用 [Apple Music-like Lyrics](https://github.com/Steve-xmh/applemusic-like-lyrics) 渲染，带专辑封面背景和播放控制。
- 自动找不到时，可以手动搜索、粘贴或导入歌词。

### 暂存架
- 把文件拖到刘海上就会展开暂存架，支持隔空投送和快速分享。

### Claude Code
- 显示正在运行的 Claude Code 会话和它们的状态。默认关闭，在设置里开启。
- 收起的刘海里，Clawd 会在 Claude 工作时敲键盘。Claude 需要授权或有问题要问时，岛会变大、闪黄色轮廓，Clawd 带着「!」蹦跳；会话完成时闪绿色轮廓，Clawd 跳一下、挥挥手再离开。
- 播放音乐时，可以选择在频谱的位置显示 Clawd 还是星号 ✻。
- 开启「在刘海中批准权限请求」后，可以点击岛直接允许或拒绝请求，也能回答 Claude 的选择题。90 秒内没有回应时，会交回 Claude Code 自己的授权流程。

开启监控会在 `~/.claude/settings.json` 中加入钩子（hooks），修改前会先备份原文件，关闭时只删除这里加入的条目。App 没有运行时，钩子什么都不做。

- 监控只记录会话状态，不保存提示词和工具输出。
- 会话在 App 启动前就已经开始时，会从它的对话记录里读出你给会话起的名字，只解析改名那一行。
- 开启刘海批准后，待批准的命令或工具参数会显示在刘海里，Claude 的提问会显示题目和选项。

### 界面语言
- 英文和简体中文。

## 系统要求

- macOS 14 Sonoma 或更高版本
- Apple 芯片或 Intel Mac

## 安装

1. 从 [Releases](../../releases) 下载 `EncoreNotch-<版本>.dmg`。
2. 打开 DMG，把 EncoreNotch 拖进「应用程序」文件夹。
3. 这个 App 没有经过 Apple 公证，第一次打开前可能需要在终端运行：

   ```bash
   xattr -dr com.apple.quarantine /Applications/EncoreNotch.app
   ```

## 从源码编译

需要 Xcode 26 或更高版本。

```bash
git clone https://github.com/LuoKeRenD/EncoreNotch.git
cd EncoreNotch
open boringNotch.xcodeproj
```

在 Xcode 里选择 `boringNotch` scheme，按 ⌘R 运行。

歌词窗口的网页已经打包好并提交在 `boringNotch/Lyrics/LyricsWeb/` 里，编译 App 不需要 Node。修改 `LyricsWeb/src/` 之后才需要重新打包：

```bash
cd LyricsWeb
npm install
npm run build
```

两个本地 Swift 包可以单独测试：

```bash
cd Packages/LyricsKit && swift test
```

```bash
cd Packages/ClaudeMonitorKit && swift test
```

### 打包发布

```bash
scripts/package.sh path/to/EncoreNotch.app
```

它会在 `dist/` 里生成 DMG 和对应的源码压缩包。按照 GPL-3.0 和 AGPL-3.0 的要求，分发 DMG 时需要一起提供源码。

## 许可证

- EncoreNotch 和它修改自的 Boring Notch 以 [GPL-3.0](LICENSE) 发布。
- 歌词窗口打包了 `@applemusic-like-lyrics/core`（AGPL-3.0-only），源码和打包配置在 `LyricsWeb/`，打包进 App 的许可证在 `boringNotch/Lyrics/LyricsWeb/THIRD_PARTY_LICENSES.txt`。
- 其他第三方组件的许可证见 [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES)。

## 致谢

- [Boring Notch](https://github.com/TheBoredTeam/boring.notch)：EncoreNotch 的基础。
- [MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter)：让 macOS 15.4 以上仍能读取 Now Playing 信息。
- [NotchDrop](https://github.com/Lakr233/NotchDrop)：暂存架功能最初的来源。
- [Apple Music-like Lyrics](https://github.com/Steve-xmh/applemusic-like-lyrics)：歌词窗口的渲染。
- [LRCLIB](https://lrclib.net)：歌词来源。
- Clawd 是 Anthropic 的 Claude Code 吉祥物，这里的像素形象依照终端里的横幅绘制。
