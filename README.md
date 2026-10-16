# Mono Maker

A small Mac app that turns the stereo sound in a video into mono, and can also remove background noise and make voices clearer. The picture is copied as-is (no re-encoding, no quality loss); only the audio is rewritten, as AAC. Everything runs on your Mac with Apple's own video and audio frameworks, so nothing is uploaded and nothing else needs installing.

Requires macOS 13 Ventura or later.

## Build it (once, about a minute)

1. Unzip this folder somewhere you'll keep it, for example Documents.
2. Open **Terminal**, type `bash ` (with a space after it), drag `build.command` from the folder onto the Terminal window, then press Return.
   (Running it this way avoids the "unidentified developer" warning a downloaded script gets when double-clicked.)
3. If you've never installed Apple's developer tools, a window will ask to install them. Click **Install**, wait for it to finish, and run step 2 again.
4. When it says **Done**, Finder shows `Mono Maker.app`. Drag it into Applications.

## Use it

- Drop videos (MOV, MP4, M4V) or a whole folder onto the window, or click **Add Videos…**.
- Each file is checked first. The L and R bars show how loud each side is, and the line under the name says what **Auto** will do:
  - sound on both sides → mixes left and right
  - sound on only one side (a lav mic on one channel, for example) → uses that side alone, so it doesn't get quieter
  - the two sides cancel each other out → uses one side
- **Sound from** lets you override Auto with Mix, Left or Right for the whole batch.
- **Save as**
  - *Mono track (1 channel)*: a true mono file.
  - *Same sound in both ears*: the mono sound written to both left and right. Pick this if an editor or player only plays mono files out of one speaker.
- **Background noise** (Off / Light / Medium / Strong) uses Apple's built-in voice isolation, the same on-device technology as the Voice Isolation mic mode. It keeps voices and removes hum, hiss, wind, traffic, fans and room noise.
  - *Light* keeps a little of the room so it still sounds natural.
  - *Strong* keeps voices only, so background **music is removed too**. Use Light or Off for videos where the music matters.
  - It's built for speech; on videos with no talking it will mostly produce silence.
- **Enhance voice** applies a gentle speech EQ: cuts rumble below 80 Hz, trims boxiness around 250 Hz, and lifts clarity around 3.5 kHz and air around 10 kHz.
- **Even out loudness** measures the whole clip and brings it to −16 LUFS (a common level for spoken video and podcasts), with a limiter so nothing clips. Quiet phone recordings come out at a normal volume.
- Click **Convert**. New files are saved next to the originals as `Name (mono).mov`, or `Name (clean).mov` when any clean-up is on; originals are never touched. Click **Show** to find a finished file.

Your clean-up settings are remembered the next time you open the app.

With clean-up on, each video is processed in two steps: the sound is cleaned first (the slower part), then the new file is saved. The progress line shows which step it's on.

The first time it saves into Desktop, Documents or Downloads, macOS asks whether Mono Maker may access that folder. Click **Allow**.

## What's in the folder

- `Sources/` – the app's Swift code: window (`MonoMakerApp.swift`), file list and settings (`Model.swift`), mono conversion (`Audio.swift`), noise removal, voice EQ and loudness (`Enhance.swift`)
- `build.command` – compiles the code into `Mono Maker.app`
- `Info.plist`, `AppIcon.icns` – the app's name, settings and icon
