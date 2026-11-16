# vcam-camera-gate

A small OBS plugin for macOS. It keeps the physical webcam closed (camera light off) unless some app is using the OBS
Virtual Camera.

## Why a plugin

OBS 33 has no built-in way to do this on macOS:

- The macOS Video Capture Device source (`macos-avcapture`) has no "Deactivate when not showing" option. That option
  exists only on Windows. Hiding the source or its scene item does not release the camera either, because the source
  has no show/hide/activate callbacks.
- The virtual camera system extension never tells OBS whether an app is watching.
- CoreMediaIO's `kCMIODevicePropertyDeviceIsRunningSomewhere` on the "OBS Virtual Camera" device does report this, but
  OBS's own feed into the extension also counts. While the virtual camera output runs, the flag stays at 1 even with no
  app watching.

## How it works

1. **Idle:** the virtual camera output is stopped and the webcam is released. The flag now means "an app is streaming",
   so a change from 0 to 1 is a reliable signal that an app has arrived. The plugin then restores the webcam and starts
   the output. During this second or so, the app shows OBS's placeholder image.
2. **Active:** the plugin tracks the client processes. It reads CoreMediaIO's start and stop lines from the unified log
   (`log stream`) and checks every second that each client process is still alive. A few seconds after the last client
   stops its camera or quits, it stops the output and reads the flag again. If the flag is 0, it releases the webcam.
   If the flag is 1, an app is still watching, so it starts the output again.

The flag is always the final word. The log only decides when to check it.

To release the webcam, the plugin clears the source's `device` setting and keeps the real device in a `vcam_gate_device`
key on the same source. It puts the device back when the camera is needed, or when you turn the plugin off. If OBS quits
or crashes while idle, the backup stays in the scene collection and the plugin restores it later. If you uninstall the
plugin while it is idle, pick the camera again in the source's properties.

## Build and install

Needs only the Xcode Command Line Tools and OBS installed at `/Applications/OBS.app` (set `OBS_APP` to use another
copy). The first build fetches the matching OBS headers and SIMDe into `.deps/`.

```zsh
./build.zsh            # builds into build/
./build.zsh install    # quit OBS first; copies into ~/Library/Application Support/obs-studio/plugins
```

## Using it

- No OBS setup is needed. The plugin turns on by default and controls the **Start/Stop Virtual Camera** button for you.
  Leave the button alone. If you stop the virtual camera by hand while an app is watching, the plugin starts it again.
- To use the webcam without a client app (for example, to record), choose **Tools → Toggle Webcam Only While Virtual
  Camera Is Used**. This turns the plugin off: the webcam comes back and OBS behaves as usual. Choose it again to turn
  the plugin back on. The setting is kept across restarts.
- Every decision is logged with the `[vcam-camera-gate]` prefix in OBS's log (**Help → Log Files**).

## Limits

- Client tracking depends on CoreMediaIO's log lines (`CMIODeviceStartStream (…)` and `Start (streamID …)`). If a
  future macOS changes them, arrival still works, because arrival uses the flag. Departure then falls back to a check
  every 15–120 s, and each check shows the app OBS's placeholder for about half a second.
- CoreMediaIO object IDs are different in each process, so a log line can't say which camera a process opened. Any
  process that turns on a camera just before or during virtual camera use counts as a client. If FaceTime uses the
  MacBook camera during that time, the webcam stays on until FaceTime stops too.
- The first launch after installing opens the webcam for about a second, before the plugin releases it.

## License

MIT. See [LICENSE](LICENSE).
