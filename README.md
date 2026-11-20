# OsmoSync

A small Mac menu bar app. When Screen Studio starts recording, OsmoSync tells your DJI Osmo camera to start recording too. When Screen Studio stops, the camera stops. When you plug the camera in for file transfer, the matching clips are copied to your Mac.

## How it works

- **Camera control:** Bluetooth, using DJI's published remote-control protocol (the "R-SDK" from [dji-sdk/Osmo-GPS-Controller-Demo](https://github.com/dji-sdk/Osmo-GPS-Controller-Demo)). The Mac acts as a Bluetooth remote. You approve it once on the camera's screen.
- **Screen Studio:** each recording gets a folder in `~/Screen Studio Projects`. OsmoSync reads Screen Studio's recorder log in that folder and reacts to `Starting recording` and `Recording stopped`. Screen Studio has a countdown, so the camera gets about two seconds' head start.
- **Copying clips:** when a volume with a `DCIM` folder mounts (the camera in file-transfer mode), OsmoSync copies the clips whose times fall inside each take. They are named after the Screen Studio project and saved to `~/Movies/Osmo Takes` (you can change this).

## Use it

```bash
make test     # core tests
make run      # build and open the app
make install  # copy to /Applications and open it
```

Needs Xcode 16 or later and `xcodegen` (`brew install xcodegen`).

1. Turn the Osmo on, open OsmoSync from the menu bar and click **Find camera**, then your camera.
2. Approve the connection on the camera's screen. It is remembered after that.
3. Click **Test record** to check it starts and stops.
4. Record in Screen Studio as normal.
5. Afterwards, plug the camera in over USB-C and choose file transfer on its screen. The clips copy over by themselves. **Import now** retries by hand.

## Limits

- The camera records to its own storage. While an app (such as Screen Studio) streams the Pocket as a **webcam**, the camera still records, but at the webcam's format (for example 1080p at 30 fps), not its own video setting. For 4K 60, turn the Osmo camera off in Screen Studio and use USB for power only. OsmoSync warns when a take starts with the webcam in use, and marks clips that came out below 4K 60.
- Recording control over the R-SDK is documented by DJI for the Osmo Action 4/5 Pro/6 and Osmo 360. The pairing has been shown to work on the Pocket 3 and 4 by other open-source apps; recording control on the Pocket still needs checking on a real camera.
- Clips are matched by time, so the camera's clock should be right (DJI Mimo sets it). With one take waiting, OsmoSync falls back to the newest clip.
- Clips copy over USB only. After a take, plug the Pocket in and pick **File transfer**; OsmoSync copies the clip to Osmo Takes, checks the copy, and lines it up with Screen Studio. The Pocket can't record in File transfer mode, so switch it back to **Charge only** before the next take. The clip stays on the camera; "Clean up camera" removes clips that already have a checked copy.
