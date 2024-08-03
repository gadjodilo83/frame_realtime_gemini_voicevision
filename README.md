# frame_flutter_stt_host (offline speech-to-text, live captioning)

Connects to Frame, streams audio from the Host (phone) microphone (for now - streaming from Frame mic coming), which is sent through a local (on Host device) [Vosk speech-to-text engine (**Unfortunately the Flutter package is Android only**)](https://pub.dev/packages/vosk_flutter), and displays the streaming text on the Frame display.

Drop in an alternative [Vosk model](https://alphacephei.com/vosk/models) to perform speech-to-text in a language other than English (`vosk-model-small-en-us-0.15` included). Frame only displays languages in a latin character set, so text might need to be tweaked before sending to Frame. The model name appears in `main.dart` and `pubspec.yaml`.

### Architecture
![Architecture](docs/Frame%20App%20Architecture%20-%20Speech-To-Text%20Host%20-%20Host%20Microphone.svg)

### See Also
- [Frame Flutter Hello Hello](https://github.com/CitizenOneX/frame_flutter_hellohello)