<p align="center">
  <img width="200" alt="RateSync Icon" src="./RateSync_Icon.png">
</p>

# RateSync 3.0 汉化版

> 本项目基于 [vincentneo/LosslessSwitcher](https://github.com/vincentneo/LosslessSwitcher)（GPL-3.0）汉化并修复而来，感谢原作者 Vincent Neo 开发了这款优秀的开源应用。

RateSync 会自动将当前音频输出设备的采样率和位深度切换到与当前播放的无损歌曲一致的值。

3.0 版本新增多应用监控支持，可同时检测 Apple Music、Spotify、网易云音乐的播放状态，通过 MediaRemote 框架探测获取当前播放信息。

例如，如果下一首播放的歌曲是采样率为 192kHz 的 Hi-Res 无损曲目，RateSync 会尽快将设备采样率切换至 192kHz。

当下一首歌曲的采样率较低时，则会做相反的处理。

## 安装

### 适用于 macOS Big Sur 11.4 至 macOS Sonoma 14.x
请使用 1.x 版本的发行版（上游原版），例如 [1.0](https://github.com/vincentneo/LosslessSwitcher/releases/tag/1.0)、1.1 或 [1.1.1 测试版](https://github.com/vincentneo/LosslessSwitcher/releases/tag/1.1.1-beta2)。
1.x 版本同样适用于 macOS Sequoia 15.3.1 及更早版本。

你可以在此处找到 1.x 分支的最新稳定版（上游原版）：[v1.1 下载链接](https://github.com/vincentneo/LosslessSwitcher/releases/tag/1.1.0)

### 适用于 macOS Sequoia 15.4 及更新版本
汉化版基于上游 2.0 分支开发，适用于 macOS Sequoia 15.4 及更新版本。当前版本为 RateSync 3.0 汉化版，最新发行版请前往 [Releases 页面](https://github.com/BiKing567/RateSync/releases) 下载。
上游原版的 2.0 测试版见：[v2.0 Beta 1](https://github.com/vincentneo/LosslessSwitcher/releases/tag/2.0-beta1)。

#### 安装步骤
1. 下载所需版本的 `.dmg` 安装镜像。
2. 将应用拖入"应用程序"文件夹。

如果你希望开机自动运行，可以在系统设置中添加 RateSync：
```
> 用户与群组 > 登录项 > 添加 RateSync 应用
```

## 应用详情

RateSync 以菜单栏应用的形式常驻运行。它通过 MediaRemote 框架实时监测来自多个音乐应用（Apple Music、Spotify、网易云音乐）的播放状态，并自动将音频输出设备的采样率和位深度切换到与当前播放歌曲一致的参数。

下图展示了监听来源选择功能，你可以选择需要监控的音乐应用：

<img width="252" alt="监听来源选择界面" src="./监听来源.png">

下图展示了内置的 EQ（均衡器）功能界面：

<img width="252" alt="EQ 均衡器功能界面" src="./EQ.png">

另请注意：
- 在应用尝试切换采样率期间，音频播放可能会出现短暂中断。
- 由于需要频繁查询最新采样率，在 MacBook 上长时间使用可能会加速电池消耗。

应用同样支持位深度切换，不过开启它会影响检测准确度，因此不建议开启。

### 为什么要做这个？
自从 Apple Music 随 macOS 11.4 推出无损功能以来，应用一直不会根据正在播放的歌曲切换采样率，只能手动前往"音频 MIDI 设置"应用调整。

即使在 macOS 12.3.1 上，这一情况仍然存在，尽管 iOS 的音乐应用早已具备此能力。

我认为这个改进会得到许多人的认可，因此这个项目免费开源地发布在这里。

## 前置条件
由于应用的工作方式，该应用没有、也无法进行沙盒化。
由于使用了 `OSLog` API，还有以下要求：
- 运行 RateSync 的用户必须是**管理员**。这一点未经测试，是基于[Apple Developer Forums 上这个帖子](https://developer.apple.com/forums/thread/677068)的推断。
- Apple Music 应用必须开启无损模式。（当然，这是必然的）

除此之外，它应该可以在任何运行 macOS 11.4 或更高版本的 Mac 上运行。

## 免责声明
使用 RateSync 即表示您同意：在任何情况下，开发者或任何贡献者均不对因以任何形式使用 RateSync 而直接或间接导致的任何索赔、损害、损失、费用、成本或责任，或您遭受的任何其他后果承担任何责任。

## 许可证
RateSync 采用 GPL-3.0 许可证。

## 喜欢这个项目？
如果你认可这个应用的开发，欢迎分享给更多人，让更多人了解 RateSync。
感谢使用！

## 依赖
- [Sweep](https://github.com/JohnSundell/Sweep)，作者 @JohnSundell，一个易于使用的 Swift 字符串扫描器。
- [SimplyCoreAudio](https://github.com/rnine/SimplyCoreAudio)，作者 @rnine，一个让 CoreAudio 使用起来更加简单的框架。
- [MediaRemoteAdapter](https://github.com/ejbills/MediaRemoteAdapter)，用于适配私有的 MediaRemote 框架。
