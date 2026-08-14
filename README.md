<p align="center">
  <img width="550" alt="header image with app icon" src="https://user-images.githubusercontent.com/23420208/164895903-1c95fe89-6198-433a-9100-8d9af32ca24f.png">

</p>

# LosslessSwitcher 汉化版

> 本项目基于 [vincentneo/LosslessSwitcher](https://github.com/vincentneo/LosslessSwitcher)（GPL-3.0）汉化并修复而来，感谢原作者 Vincent Neo 开发了这款优秀的开源应用。

LosslessSwitcher 会自动将当前音频输出设备的采样率切换到与 Apple Music 正在播放的无损歌曲一致的采样率。

例如，如果下一首播放的歌曲是采样率为 192kHz 的 Hi-Res 无损曲目，LosslessSwitcher 会尽快将设备采样率切换至 192kHz。

当下一首歌曲的采样率较低时，则会做相反的处理。

## 安装

### 适用于 macOS Big Sur 11.4 至 macOS Sonoma 14.x
请使用 1.x 版本的发行版（上游原版），例如 [1.0](https://github.com/vincentneo/LosslessSwitcher/releases/tag/1.0)、1.1 或 [1.1.1 测试版](https://github.com/vincentneo/LosslessSwitcher/releases/tag/1.1.1-beta2)。
1.x 版本同样适用于 macOS Sequoia 15.3.1 及更早版本。

你可以在此处找到 1.x 分支的最新稳定版（上游原版）：[v1.1 下载链接](https://github.com/vincentneo/LosslessSwitcher/releases/tag/1.1.0)

### 适用于 macOS Sequoia 15.4 及更新版本
汉化版基于上游 2.0 分支开发，请下载本仓库的发行版：[LosslessSwitcher 2.1 汉化版（v2.1）](https://github.com/BiKing567/LosslessSwitcher/releases/tag/v2.1)。
上游原版的 2.0 测试版见：[v2.0 Beta 1](https://github.com/vincentneo/LosslessSwitcher/releases/tag/2.0-beta1)。

#### 安装步骤
1. 下载所需版本的 `.dmg` 安装镜像。
2. 将应用拖入"应用程序"文件夹。

如果你希望开机自动运行，可以在系统设置中添加 LosslessSwitcher：
```
> 用户与群组 > 登录项 > 添加 LosslessSwitcher 应用
```

## 应用详情

应用的界面非常简单，大部分逻辑在于：
1. 读取 Apple Music 的日志以获取歌曲的采样率。
2. 将采样率设置为当前播放所使用设备的采样率。

因此，应用常驻于菜单栏。上方的截图展示了它唯一的界面元素——显示从 Apple Music 日志中解析出的采样率。

<img width="252" alt="应用截图，显示音乐音符图标作为 UI 按钮" src="https://user-images.githubusercontent.com/23420208/164895657-35a6d8a3-7e85-4c7c-bcba-9d03bfd88b4d.png">

如果你愿意，采样率也可以直接显示为菜单栏项目。

<img width="252" alt="应用截图，显示采样率作为 UI 按钮" src="https://user-images.githubusercontent.com/23420208/164896404-c6d27328-47e5-4eb3-bd8b-71e3c9013c46.png">

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
- 运行 LosslessSwitcher 的用户必须是**管理员**。这一点未经测试，是基于[Apple Developer Forums 上这个帖子](https://developer.apple.com/forums/thread/677068)的推断。
- Apple Music 应用必须开启无损模式。（当然，这是必然的）

除此之外，它应该可以在任何运行 macOS 11.4 或更高版本的 Mac 上运行。

## 免责声明
使用 LosslessSwitcher 即表示您同意：在任何情况下，开发者或任何贡献者均不对因以任何形式使用 LosslessSwitcher 而直接或间接导致的任何索赔、损害、损失、费用、成本或责任，或您遭受的任何其他后果承担任何责任。

## 已测试设备

以下是 LosslessSwitcher 用户测试可用的部分设备组合。
尽管如此，仍需提醒您自行承担使用 LosslessSwitcher 的风险。

### 版本 1.x
| CPU | Mac 型号 | macOS 版本 | 测试版 macOS？ | 音频设备 |
| --------------- | ---------------------------------------------------- | ------------------ | ----------- | ------------------------------------------------------------ |
| Intel | MacBook Pro 13 英寸（2015 年初，双核 i5） | 11.6.2 | 否 | Denon AVR-X4400H |
| Intel | Mac mini (2018) | 12.2<br/>12.4 | 否 | Denon PMA-50 |
| Intel | MacBook Pro 13 英寸 (2018) | 12.3.1 | 否 | Denon PMA-50 |
| Intel | MacBook Pro 13 英寸，四个雷雳 3 端口 (2016) | 12.3.1 | 否 | Topping DX7 Pro |
| Apple Silicon | MacBook Pro 13 英寸 (M1, 2020) | 12.3.1 | 否 | FX Audio DAC-X6 |
| Intel | MacBook Pro 15 英寸 (2016) | 12.4 | 否 | Topping D30Pro |
| Apple Silicon | Mac mini (M1, 2020) | 12.4 | 否 | Meridian Explorer 2 |
| Intel | 黑苹果 (XPS 9570, i7-8750H) | 12.4 | 否 | Universal Audio Apollo X4<br/>FiiO Q3<br/>FiiO M5（DAC 模式） |
| Intel | MacBook Pro 13 英寸 (2016) | 12.4<br/>12.6.1 | 否 | AudioQuest Dragonfly Cobalt |
| Apple Silicon | Mac mini (M1, 2020) | 12.4 | 否 | iFi Zen DAC V2 |
| Intel | MacBook Pro 15 英寸 (2018) | 12.4 | 否 | PS Audio Sprout |
| Apple Silicon | MacBook Air 13 英寸 (2020) | 12.5.1 | 否 | Shanling M8 |
| Apple Silicon | Mac Studio (M1 Max, 2022) | 12.6 | 否 | Focusrite Scarlett 18i8（第二代） |
| Intel | MacBook Pro 16 英寸 (2019) | 12.6 | 否 | Mytek Brooklyn+ DAC |
| Intel | Mac mini（2014 年末） | 12.6.3 | 否 | NAD C658 |
| Apple Silicon | Mac mini (M1, 2020) | 13.0 | 22A5286j | Topping D50s |
| Apple Silicon | Mac mini (M1, 2020) | 13.0 | 否 | iBasso DC06<br/>Khadass Tone 2 Pro |
| Apple Silicon | MacBook Pro 14 英寸 (M1 Pro, 2021) | 13.0<br/>13.0.1 | 否 | Topping D10 Balanced |
| Apple Silicon | Mac mini (M1, 2020) | 13.0.1 | 否 | Fiio K7<br/>Fiio K5 Pro（AKM DAC）<br/>Topping EX5 |
| Apple Silicon | MacBook Pro 14 英寸 (2021) | 13.0.1 | 否 | AudioQuest Dragonfly Black v1.5 |
| Apple Silicon | MacBook Air (M1, 2020) | 13.1 | 否 | Schiit Bifrost 2 |
| Intel | MacBook Pro 15 英寸 (2018) | 13.1 | 否 | Apogee Groove |
| Apple Silicon | iMac 24 英寸 (M1, 2021) | 13.1 | 否 | SMSL PO100 |
| Apple Silicon | MacBook Pro 14 英寸 (2021) | 13.1 | 否 | Chord Mojo |
| Apple Silicon | Mac mini (M1, 2020) | 13.2 | 否 | RME ADI-2 DAC FS |
| Apple Silicon | MacBook Pro 16 英寸 (M1 Max, 2021) | 13.2 | 否 | M-Audio Fast Track |
| Apple Silicon | MacBook Pro 14 英寸 (2021) | 13.2 | 否 | Topping D10s |
| Apple Silicon | Mac Studio (M1 Max, 2022) | 13.2.1 | 否 | RME ADI-2 PRO FS R（黑色版） |
| Intel | 27 英寸 iMac (2017) | 13.2.1 | 否 | Chord Hugo M Scaler + TT2 Combo |
| Apple Silicon | Mac mini (M1, 2020) | 13.2.1 | 否 | Moondrop Moonriver 2 |
| Apple Silicon | MacBook Pro 13 英寸 (M1, 2020) | 13.3.1 | 否 | Gustard X18 |
| Intel | 27 英寸 iMac（2014 年末） | 13.3.1 (a) | 否 | SMSL M500 |
| Apple Silicon | Mac mini (M2 Pro, 2023) | 13.5 | 否 | FiiO K5 Pro |
| Apple Silicon | Mac mini (M2 Pro, 2023) | 13.5 | 否 | JDS Labs Element III MK 2 |
| Intel | Mac mini（2014 年末） | 13.5（OpenCore） | 否 | VLink192 to Rega DAC |
| Intel | MacBook Pro 16 英寸 (2019) | 13.6.4 | 否 | VMV D1SE |
| Intel | MacBook Pro 16 英寸 (2019) | 13.6.4 | 否 | Denon AVR-X6700H |
| Apple Silicon | MacBook Pro 16 英寸 (M1 Max, 2021) | 14.0 | 23A5328b | Focusrite Scarlett 2i2（第三代）、MacBook 内置 DAC |
| Intel | MacBook Air 13 英寸 (2020 i5 1.1GHz 四核) | 14.0 | 23A5328d | PreSonus Studio 1810c |
| Apple Silicon | MacBook Air 13 英寸 (M1, 2020) | 14.0 | 否 | Cambridge Audio DacMagic 100 |
| Apple Silicon | Mac Studio (M1 Max, 2022) | 14.4.1 | 否 | Hidizs S9 PRO |
| Apple Silicon | MacBook Air 13 英寸 (M2, 2022) | 14.4.1 | 否 | Cambridge Audio DacMagic XS |
| Apple Silicon | MacBook Pro 14 英寸 (M3 Pro, 2024) | 14.4.1 | 否 | RME ADI-2 PRO FS R（黑色版） |
| Intel | Mac Pro 6.1 (2013) | 14.4.1（OpenCore） | 否 | Cambridge Audio Edge NQ |
| Apple Silicon | MacBook Air 13 英寸 (M2, 2022) | 14.5 | 否 | HiBy FD3 |
| Apple Silicon | MacBook Pro 14 英寸 (M1 Pro, 2021) | 14.6.1 | 否 | FiiO BTR15 |
| Apple Silicon | MacBook Air 13 英寸 (M3, 2024) | 14.6.1 | 否 | iBasso DC03 Pro |
| Intel | MacBook Pro 16 英寸 (i7, 2019) | 14.6.1 | 否 | Fiio KA17 |
| Apple Silicon | MacBook Pro 16 英寸 (M1 Max, 2021) | 15.0 | 24A5264n | 内置声卡<br/>Focusrite 2i2（第三代）<br/>M-Track 2x2 |
| Intel | MacBook Pro 15 英寸 (2012) | 15.1（OpenCore） | 24B5035e | Fiio KA3<br/>Fiio KB3 |
| Apple Silicon | Mac mini (M2, 2023) | 15.1.1 | 否 | Sony NW-A55（USB DAC 模式） |
| Apple Silicon | Mac mini (M4, 2024) | 15.3.1 | 否 | MOTU M2 |

### 版本 2.x
| CPU | Mac 型号 | macOS 版本 | 测试版 macOS？ | 音频设备 | 版本 |
| --------------- | ---------------------------------------------------- | ------------------ | ----------- | -----------------------------------|------------|
| Apple Silicon | MacBook Pro 13 英寸 (M1, 2020) | 15.4.1 | 否 | Cambridge Audio CXA81 | 2.0 Beta 1 |
| Apple Silicon | Mac Studio (M1 Max, 2022) | 15.4.1 | 否 | Denon PMA-150H | 2.0 Beta 1 |
| Apple Silicon | MacBook Pro 13 英寸 (M1, 2020) | 15.5 | 否 | Cambridge Audio CXA81 | 2.0 Beta 2 |
| Apple Silicon | MacBook Pro 14 英寸 (M1 Max, 2021) | 15.5 | 否 | Cambridge Audio DacMagic 200M | 2.0 Beta 2 |
| Apple Silicon | MacBook Pro 14 英寸 (M4 Pro, 2024) | 15.5 | 否 | Cambridge Audio CXA81 | 2.0 Beta 2 |
| Intel | Mac Pro 6.1 (2013) + OpenCore Patcher | 15.5 | 否 | Cambridge Audio Edge NQ | 2.0 Beta 2 |
| Apple Silicon | MacBook Air 13 英寸 (M4, 2025) | 15.6.1 | 否 | Akliam PD5 | 2.0 Beta 2 |
| Apple Silicon | Mac mini (M4, 2024) | 15.6.1 | 否 | Focusrite Scarlett 2i2（第四代） | 2.0 Beta 2 |
| Intel | MacBook Pro 15 英寸 (2.3GHz i9, 2019) | 15.7.3 | 否 | Fiio KA3 | 2.0 Beta 2 |
| Apple Silicon | MacBook Pro 14 英寸 (M2 Pro, 2023) | 26.0 | 公测版 2 | AudioQuest Dragonfly Red | 2.0 Beta 2 |
| Apple Silicon | MacBook Pro 14 英寸 (M3 Pro, 2023) | 26.0.1 | 否 | Fiio K11 | 2.0 Beta 2 |
| Apple Silicon | MacBook Pro 14 英寸 (M1 Pro, 2021) | 26.1 | 开发者测试版 2 | iBasso DC Elite | 2.0 Beta 2 |
| Apple Silicon | Mac mini (M1, 2020) | 26.1 | 否 | Fiio K11 | 2.0 Beta 2 |
| Apple Silicon | Mac mini (M1, 2020) | 26.1 | 否 | Ayre QB-9 Twenty | 2.0 Beta 2 |
| Apple Silicon | MacBook Air 13 英寸 (M3, 2024) | 26.3 | 否 | Fiio K17 | 2.0 Beta 3 |
| Apple Silicon | MacBook Air 13 英寸 (M1, 2020) | 26.3.1 | 否 | Fosi Audio K5 Pro | 2.0 |

你可以修改本 README 并提交新的 Pull Request，将你的设备添加到列表中！

请注意，Steven Slate Audio VSX 软件可能与 LosslessSwitcher 不完全兼容，两者可能会相互干扰。更多信息请参阅[讨论 #100](https://github.com/vincentneo/LosslessSwitcher/discussions/100)。

## 许可证
LosslessSwitcher 采用 GPL-3.0 许可证。

## 喜欢这个项目？
如果你认可这个应用的开发，欢迎分享给更多人，让更多人了解 LosslessSwitcher。
感谢使用！

## 依赖
- [Sweep](https://github.com/JohnSundell/Sweep)，作者 @JohnSundell，一个易于使用的 Swift 字符串扫描器。
- [SimplyCoreAudio](https://github.com/rnine/SimplyCoreAudio)，作者 @rnine，一个让 CoreAudio 使用起来更加简单的框架。
- [PrivateMediaRemote](https://github.com/PrivateFrameworks/MediaRemote)，作者 @DimitarNestorov，用于使用私有的媒体远程框架。
