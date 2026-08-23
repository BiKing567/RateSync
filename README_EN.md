<p align="center">
  <img width="200" alt="RateSync Icon" src="./RateSync_Icon.png">
</p>

<h1 align="center">RateSync</h1>

[简体中文](README.md) | English

<p align="center">
  <img src="https://img.shields.io/github/v/release/BiKing567/RateSync?style=flat-square" alt="release">
  <img src="https://img.shields.io/badge/license-GPL--3.0-green?style=flat-square" alt="license">
  <img src="https://img.shields.io/github/downloads/BiKing567/RateSync/total?style=flat-square" alt="downloads">
  <img src="https://img.shields.io/badge/macOS-15.4%2B-blue?style=flat-square" alt="macOS">
</p>

> This project is a localized & modified fork of [vincentneo/LosslessSwitcher](https://github.com/vincentneo/LosslessSwitcher) (GPL-3.0). Many thanks to the original author Vincent Neo for this excellent open-source app.

RateSync automatically switches the sample rate and bit depth of your current audio output device to match the lossless song currently playing.

Version 3.0 adds multi-app monitoring support: it can detect the playback state of Apple Music, Spotify, and NetEase Cloud Music at the same time, probing current playback info through the MediaRemote framework.

For example, if the next song is a Hi-Res lossless track with a 192 kHz sample rate, RateSync will switch the device's sample rate to 192 kHz as soon as possible.

When the next song has a lower sample rate, it does the opposite.

## Installation

### For macOS Big Sur 11.4 through macOS Sonoma 14.x
Please use the upstream 1.x releases, such as [1.0](https://github.com/vincentneo/LosslessSwitcher/releases/tag/1.0), 1.1, or the [1.1.1 beta](https://github.com/vincentneo/LosslessSwitcher/releases/tag/1.1.1-beta2).
The 1.x releases also work on macOS Sequoia 15.3.1 and earlier.

You can find the latest stable release on the 1.x branch (upstream) here: [v1.1 download link](https://github.com/vincentneo/LosslessSwitcher/releases/tag/1.1.0)

### For macOS Sequoia 15.4 and later
This localized version is based on the upstream 2.0 branch and targets macOS Sequoia 15.4 and later. The current version is RateSync 3.0 (localized edition); please download the latest release from the [Releases page](https://github.com/BiKing567/RateSync/releases).
The upstream 2.0 beta can be found here: [v2.0 Beta 1](https://github.com/vincentneo/LosslessSwitcher/releases/tag/2.0-beta1).

#### Installation steps
1. Download the `.dmg` image of the version you need.
2. Drag the app into the "Applications" folder.

If you want RateSync to launch automatically at login, add it in System Settings:
```
> Users & Groups > Login Items > Add the RateSync app
```

## App details

RateSync runs resident in the menu bar. It monitors the playback state of multiple music apps (Apple Music, Spotify, NetEase Cloud Music) in real time via the MediaRemote framework, and automatically switches the sample rate and bit depth of your audio output device to match the currently playing song.

The screenshot below shows the monitoring-source picker, where you can choose which music apps to monitor:

<img width="252" alt="Monitoring source selection interface" src="./监听来源.png">

The screenshot below shows the built-in EQ (equalizer) interface:

<img width="252" alt="EQ equalizer interface" src="./EQ.png">

Also note:
- Audio playback may be briefly interrupted while the app switches the sample rate.
- Because it polls for the latest sample rate frequently, extended use on a MacBook may accelerate battery drain.

The app also supports bit depth switching, but enabling it reduces detection accuracy, so it is not recommended.

### Why does this exist?
Ever since Apple Music introduced lossless audio in macOS 11.4, the app has refused to switch the sample rate based on the song being played — you had to open Audio MIDI Setup and adjust it manually.

Even on macOS 12.3.1 this is still the case, despite the iOS Music app having had this capability for a long time.

I believe many people would appreciate this improvement, which is why this project is published here, free and open source.

## Prerequisites
Due to how the app works, it is not — and cannot be — sandboxed.
Because it uses the `OSLog` API, there are additional requirements:
- The user running RateSync must be an **administrator**. This is untested and inferred from [this thread on the Apple Developer Forums](https://developer.apple.com/forums/thread/677068).
- Lossless must be enabled in the Apple Music app. (Needless to say.)

Other than that, it should run on any Mac with macOS 11.4 or later.

## Disclaimer
By using RateSync, you agree that under no circumstances shall the developer or any contributor be held liable for any claims, damages, losses, expenses, costs, or liabilities, or any other consequences you may suffer, arising directly or indirectly from the use of RateSync in any form.

## License
RateSync is licensed under GPL-3.0.

## Like this project?
If you appreciate the development of this app, feel free to share it with more people and help spread the word about RateSync.
Thanks for using it!

## Dependencies
- [Sweep](https://github.com/JohnSundell/Sweep) by @JohnSundell — an easy-to-use Swift string scanner.
- [SimplyCoreAudio](https://github.com/rnine/SimplyCoreAudio) by @rnine — a framework that makes CoreAudio easier to work with.
- [MediaRemoteAdapter](https://github.com/ejbills/MediaRemoteAdapter) — an adapter for the private MediaRemote framework.
