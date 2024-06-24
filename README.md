# frame_flutter_stt_host (offline speech-to-text, live captioning)

Connects to Frame and streams audio from its microphone, which is sent through a local (on Host device) [Vosk speech-to-text engine (Flutter package is Android only)](https://pub.dev/packages/vosk_flutter), and displays the streaming text on the Frame display.

Drop in an alternative [Vosk model](https://alphacephei.com/vosk/models) to perform speech-to-text in a language other than English (`vosk-model-small-en-us-0.15` included).

### Architecture
![Architecture](docs/Frame%20App%20Architecture%20-%20Speech-To-Text%20Host.svg)

### See Also
- [Frame Flutter Translate Host](https://github.com/CitizenOneX/frame_flutter_translate_host)
- [Frame Flutter Hello World](https://github.com/CitizenOneX/frame_flutter_helloworld)