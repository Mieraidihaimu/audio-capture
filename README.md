# Audio Capture

A native menu bar recorder with WhisperKit transcription for **macOS Tahoe 26 or later**, built for Apple silicon and Intel. The app uses Apple's audio APIs directly and saves recordings locally. Capture starts from the menu when you click **Start Recording**.

## Try it

1. Unzip the app, open **Audio Capture.app**, and click the waveform icon in the menu bar.
2. Choose a system audio source.

   | Source | What it captures | macOS permission |
   | --- | --- | --- |
   | Selected app | Output from the chosen app's Core Audio processes. Play audio in the app first, click refresh, and select it. | System Audio Recording |
   | All output · Core Audio | System-wide playback through a private process tap. | System Audio Recording |
   | ScreenCaptureKit | System audio from a stream attached to the main display. The app registers only the audio output. | Screen & System Audio Recording |

3. Turn on **Include microphone** if you want a second track, then click **Start Recording**. Grant the applicable macOS permissions when prompted. Startup can wait for your response. Use the level meters to verify the sources while audio is playing and while you speak.
4. Click **Stop Recording**. With **Transcribe after recording** on, WhisperKit starts once the audio files are saved. Click **Last session** to open the audio and transcript files in Finder.

**Recordings** opens `~/Library/Application Support/Audio Capture/Recordings`. Each session folder can contain `system.caf` and `microphone.caf`, both 32-bit floating-point PCM. The tracks retain their input sample rates. Their start times and clocks are independent, so align them manually if you mix them.

Selected-app mode includes audio from all tabs and windows sharing the tapped processes. The tap can restore previously tapped processes by bundle ID when they relaunch. If the app starts an additional audio helper, play audio and refresh the list before starting a new session.

## Dictate from any app

With Audio Capture running, hold **Option–Space** to record microphone dictation and release it to finish. A floating waveform appears in the center of the current display and responds to the microphone level. WhisperKit then transcribes the recording and copies plain text to your clipboard, ready for **Command–V**. The menu shows **Dictation copied to clipboard** when it finishes.

You can also click **Dictate** in the menu, then **Finish & Copy** to end that recording.

Dictation requests microphone permission on first use and saves its audio and timestamped transcript in a session folder. Use the shortcut once the current recording or transcription finishes. The menu reports a shortcut conflict if another app already uses Option–Space.

## Browse transcripts

Choose **Transcripts…** in the menu to browse saved transcripts. Select a transcript to read it, use **Copy Text** to copy its speech, or **Show in Finder** to open its location. **Move to Trash** moves that transcript file to the Mac's Trash.

The browser discovers earlier transcripts in the Recordings folder and remembers sessions imported through **Transcribe a Session…**. Use **Refresh** to pick up changes made in Finder.

## Speech to text

Transcription runs locally after capture and detects the spoken language. The app includes the multilingual Whisper Base model and tokenizer. Transcription works offline from the first run. Audio stays on this Mac. [Argmax Whisper Base model files](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-base)

Each track gets its own UTF-8 transcript, `system.txt` or `microphone.txt`. Timestamps are measured from the start of that track. The system track can include several speakers.

Use **Transcribe a Session…** to select an earlier recording folder or retry a session after an error. Existing transcripts are preserved. **Cancel** leaves audio and any completed transcript files in place. **Stop & Quit** saves audio for later transcription.

## Build from source

Use Xcode 26 or later with the macOS SDK selected by `xcode-select`. The build resolves the pinned Swift packages and fetches the model files over the network. From this source folder, run:

```sh
./build.sh
open "build/Audio Capture.app"
```

The script builds a universal app, applies an ad hoc signature for local testing, and verifies the signature. It verifies the model files against SHA-256 checksums and includes them in the signed app. To reuse a previous WhisperKit download at build time, set `WHISPERKIT_CACHE_DIR` to the folder containing its `models` directory. To choose a different destination, pass a new path ending in `.app` as the first argument.

## Capture implementation

- Core Audio process taps and private aggregate devices provide the selected-app and system-wide modes. Playback remains audible. [Apple's Core Audio tap sample](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps)
- ScreenCaptureKit provides the alternate system-audio mode and excludes Audio Capture's own audio. [Apple's ScreenCaptureKit audio documentation](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio)
- `AVAudioEngine` taps the default microphone. `ExtAudioFileWriteAsync` queues PCM writes, and stopping capture flushes the files.

- WhisperKit 1.1.1 loads the saved PCM audio and runs Whisper Base through Core ML. [Argmax file transcription documentation](https://app.argmaxinc.com/docs/examples/file-transcription)
