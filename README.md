# OsmoSync

A Mac menu bar app that makes a DJI Osmo Pocket 4P record in full quality alongside Screen Studio.

When Screen Studio starts recording, OsmoSync tells the Pocket to start recording to its own storage. When Screen Studio stops, the Pocket stops. When you then plug the Pocket in for file transfer, OsmoSync copies the clip to your Mac, checks it, and lines it up with the Screen Studio recording by sound.

## Why

You can use the Pocket as a USB webcam in Screen Studio, but the webcam stream is compressed. Worse, while the Pocket streams as a webcam, its own recording follows the webcam's format (for example 1080p at 30 fps), not its video setting. To get the camera's full 4K 60 footage, the Pocket has to record on its own, with no webcam stream. OsmoSync starts and stops that recording for you, so it always matches your Screen Studio take.

## How it works

- **Camera control:** the Mac pairs with the Pocket over Bluetooth, then talks to it over your home Wi-Fi using DJI's DUML protocol, to start and stop recording and read its status.
- **Screen Studio:** OsmoSync watches Screen Studio's recorder log in `~/Screen Studio Projects` and reacts when a recording starts and stops.
- **Copying:** when the Pocket mounts as a drive (File transfer mode), OsmoSync copies the clips whose times fall inside each take to `~/Movies/Osmo Takes`, named after the Screen Studio project. It checks each copy is the same size as the original, warns if a clip came out below 4K 60, and makes a synced copy lined up with the Screen Studio audio.

## Requirements

- A Mac on macOS 14 or later.
- Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) to build it.
- Optional: ffmpeg (`brew install ffmpeg`). OsmoSync uses `ffprobe` to read clip lengths when it's there, and AVFoundation when it isn't.
- A DJI Osmo Pocket 4P on the same Wi-Fi network as the Mac. Other Pocket and Osmo models may work but are untested.
- Screen Studio.

## Build and install

```bash
make test     # core tests
make install  # build, copy to /Applications, and start at login
```

## Set up

1. On the Pocket, set the video mode to 4K 60 (or whatever you want to record).
2. Connect the Pocket to the Mac over USB-C and pick **Charge only** on its screen. In **File transfer** mode the Pocket won't record.
3. In Screen Studio, set the camera to **No camera**, so the Pocket isn't streaming as a webcam.
4. Open OsmoSync from the menu bar, click **Find camera** and pick your Pocket. Approve the connection on the Pocket's screen. OsmoSync then moves the camera onto your home Wi-Fi, which it uses for control.
5. Click **Test record** to check it starts and stops.
6. Record in Screen Studio as normal.
7. Afterwards, replug the Pocket and pick **File transfer**. The clip copies over by itself. Switch back to **Charge only** before the next take.

## Limits

- OsmoSync can't switch the Pocket between Charge only and File transfer. You do that on the camera's screen. The Pocket refuses the old DJI "USB switch" commands.
- DUML is undocumented. Everything here was worked out from other open-source projects and from what the camera sends back, so a firmware update could break it.
- Clips are matched by time, so the camera's clock should be right (DJI Mimo sets it).
- Clips stay on the camera after copying. **Clean up camera** removes clips that already have a checked copy on the Mac, after asking.

## Credits

OsmoSync builds on public protocol work by others. See [NOTICE](NOTICE) for details and licences.

- [OpenPocketCine](https://github.com/erik-sutton95/OpenPocketCine) (Apache-2.0): DUML framing, the Wi-Fi datalink, station join and the camera status layout.
- [OsmoOffload](https://github.com/intermittech/OsmoOffload) (MIT): the media list layout, file deletion and resumable downloads.
- [Osmosis](https://github.com/KonradIT/osmosis) (MIT): early DUML captures.
- [DJI Osmo GPS Controller Demo](https://github.com/dji-sdk/Osmo-GPS-Controller-Demo): DJI's published R-SDK Bluetooth protocol.

## Licence

MIT. See [LICENSE](LICENSE).

Not affiliated with DJI or Screen Studio. DJI, Osmo and Osmo Pocket are trademarks of SZ DJI Technology Co., Ltd.
