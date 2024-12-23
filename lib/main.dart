import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:frame_realtime_gemini_voicevision/audio_data_extractor.dart';
import 'package:frame_realtime_gemini_voicevision/audio_upsampler.dart';
import 'package:logging/logging.dart';
import 'package:raw_sound/raw_sound_player.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_frame_app/rx/audio.dart';
import 'package:simple_frame_app/rx/tap.dart';
import 'package:simple_frame_app/tx/code.dart';
import 'package:simple_frame_app/tx/plain_text.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'foreground_service.dart';

void main() {
  // Set up Android foreground service
  initializeForegroundService();

  runApp(const MainApp());
}

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  MainAppState createState() => MainAppState();
}

/// SimpleFrameAppState mixin helps to manage the lifecycle of the Frame connection outside of this file
class MainAppState extends State<MainApp> with SimpleFrameAppState {

  /// realtime voice application members
  final TextEditingController _apiKeyController = TextEditingController();
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSubs;
  bool _conversing = false;
  // TODO interestingly, 'response_modalities' seems to allow only "text", "audio", "image" - not a list. Audio only is fine for us
  final Map<String, dynamic> _setupMap = {'setup': { 'model': 'models/gemini-2.0-flash-exp', 'generation_config': {'response_modalities': 'audio'}}};
  final Map<String, dynamic> _realtimeInputMap = {'realtimeInput': { 'mediaChunks': [{'mimeType': 'audio/pcm;rate=16000', 'data': ''}]}};

  // raw sound player
  final _player = RawSoundPlayer();

  // tap subscription and audio streaming status
  StreamSubscription<int>? _tapSubs;
  bool _streaming = false;
  // 8kHz 16-bit linear PCM from Frame mic (only the high 10 bits iirc)
  final RxAudio _rxAudio = RxAudio(streaming: true);
  StreamSubscription<Uint8List>? _audioSubs;
  Stream<Uint8List>? _audioSampleStream;

  // UI display
  final List<String> _eventLog = List.empty(growable: true);
  final ScrollController _eventLogController = ScrollController();
  static const _textStyle = TextStyle(fontSize: 20);
  String? _errorMsg;

  MainAppState() {
    // filter logging
    hierarchicalLoggingEnabled = true;
    Logger.root.level = Level.FINE;
    Logger('Bluetooth').level = Level.OFF;
    Logger('RxAudio').level = Level.FINE;
    Logger('RxTap').level = Level.FINE;

    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: [${record.loggerName}] ${record.time}: ${record.message}');
    });
  }

  @override
  void initState() {
    super.initState();

    // use a small buffer to allow short clips to be played - raw_sound won't play clips smaller than bufferSize bytes
    // gemini pcm16 is apparently mono 24kHz
    // kick off asynchronously
    _player.initialize(bufferSize: 32768, nChannels: 1, sampleRate: 24000, pcmType: RawSoundPCMType.PCMI16);

    // load up the saved text field data
    _loadPrefs()
      // then kick off the connection to Frame and start the app if possible
      .then((_) => tryScanAndConnectAndStart(andRun: true));
  }

  @override
  void dispose() async {
    await _channel?.sink.close();
    await _player.release();
    await _audioSubs?.cancel();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _apiKeyController.text = prefs.getString('api_key') ?? '';
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_key', _apiKeyController.text);
  }

  /// This application uses Gemini's realtime API over WebSockets.
  /// It has a running main loop in this function and also on the Frame (frame_app.lua)
  @override
  Future<void> run() async {
    // validate API key exists at least
    _errorMsg = null;
    if (_apiKeyController.text.isEmpty) {
      setState(() {
        _errorMsg = 'Error: Set value for Gemini API Key';
      });

      return;
    }

    setState(() {
      currentState = ApplicationState.running;
      _eventLog.clear();
    });

    try {
      // listen for double taps to start/stop transcribing
      _tapSubs?.cancel();
      _tapSubs = RxTap().attach(frame!.dataResponse)
        .listen((taps) async {
          if (taps >= 2) {
            if (!_streaming && !_conversing) {
              _streaming = true;
              await frame!.sendMessage(TxPlainText(msgCode: 0x0b, text: 'Connecting...'));

              await _startConversation();

              // show microphone emoji
              await frame!.sendMessage(TxPlainText(msgCode: 0x0b, text: '\u{F0010}'));
            }
            else if (_streaming && _conversing) {
              await _stopConversation();
              _streaming = false;

              // prompt the user to begin tapping
              await frame!.sendMessage(TxPlainText(msgCode: 0x0b, text: 'Double-Tap to resume!'));
            }
            else {
              _log.severe('double-tap while streaming and conversing status is not aligned');
            }
          }
          // ignore spurious 1-taps
        });

      // let Frame know to subscribe for taps and send them to us
      await frame!.sendMessage(TxCode(msgCode: 0x10, value: 1));

      // prompt the user to begin tapping
      await frame!.sendMessage(TxPlainText(msgCode: 0x0b, text: 'Double-Tap to begin!'));

    } catch (e) {
      _errorMsg = 'Error executing application logic: $e';
      _log.fine(_errorMsg);

      setState(() {
        currentState = ApplicationState.ready;
      });
    }
  }

  /// Once running(), audio streaming is controlled by taps. But the user can cancel
  /// here as well, whether they are currently streaming audio or not.
  @override
  Future<void> cancel() async {
    setState(() {
      currentState = ApplicationState.canceling;
    });

    // cancel the subscription for taps
    _tapSubs?.cancel();

    // cancel the conversation if it's running
    if (_conversing) _stopConversation();

    // tell the Frame to stop streaming audio (regardless of if we are currently)
    await frame!.sendMessage(TxCode(msgCode: 0x30, value: 0));

    // let Frame know to stop sending taps too
    await frame!.sendMessage(TxCode(msgCode: 0x10, value: 0));

    // clear the display
    await frame!.sendMessage(TxPlainText(msgCode: 0x0b, text: ' '));

    setState(() {
      currentState = ApplicationState.ready;
    });
  }

  /// When we receive a tap to start the conversation, we need to start
  /// audio streaming on Frame and start the WebRTC conversation with OpenAI
  Future<void> _startConversation() async {
    _appendEvent('Starting conversation');

    // get a fresh websocket channel each time we start a conversation for now
    await _channel?.sink.close();
    _channel = WebSocketChannel.connect(Uri.parse('wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent?key=${_apiKeyController.text}'));

    // connection doesn't complete immediately, wait until it's ready
    // TODO check what happens if API key is bad, host is bad etc, how long are the timeouts?
    await _channel!.ready;

    // set up the config for the model/modality
    _channel!.sink.add(jsonEncode(_setupMap));

    // set up stream handler for channel to handle events
    _channelSubs = _channel!.stream.listen(_handleGeminiEvent);

    // Gemini side is set up
    _conversing = true;

    try {
      // the audio stream from Frame, which needs to be closed() to stop the streaming
      _audioSampleStream = _rxAudio.attach(frame!.dataResponse);
      _audioSubs?.cancel();
      // TODO consider buffering if 128 bytes of PCM16 / 64 bytes of ulaw is too little (e.g. if measured in requests not tokens)
      _audioSubs = _audioSampleStream!.listen(_handleFrameAudio);

      // tell Frame to start streaming audio
      await frame!.sendMessage(TxCode(msgCode: 0x30, value: 1));

    } catch (e) {
      _log.warning(() => 'Error executing application logic: $e');
    }
  }

  /// handle the server events that come through the websocket
  FutureOr<void> _handleGeminiEvent(dynamic eventJson) async {
    String eventString = utf8.decode(eventJson);

    // parse the json
    var event = jsonDecode(eventString);

    // try audio message types first
    var audioData = AudioDataExtractor.extractAudioData(event);

    if (audioData != null) {
      for (var chunk in audioData) {
        await _playAudio(chunk);
      }
    }
    else {
      // some other kind of event
      var serverContent = event['serverContent'];
      if (serverContent != null) {
        if (serverContent['interrupted'] != null) {
          // TODO process interruption
          _stopAudio();
          // TODO communicate interruption playback point back to server?
          _appendEvent('---Interruption---');
        }
        else if (serverContent['turnComplete'] != null) {
          // server has finished sending
          _appendEvent('Server turn complete');
        }
      }
      else if (event['setupComplete'] != null) {
        _appendEvent('Setup is complete');
      }
      else {
        // unknown server message
        _log.info(eventString);
        _appendEvent(eventString);
      }
    }
  }

  /// pass the audio from Frame (upsampled) to the API
  void _handleFrameAudio(Uint8List pcm16x8) {
    if (_conversing) {
      // upsample PCM16 from 8kHz to 16kHz for Gemini
      var pcm16x16 = AudioUpsampler.upsample8kTo16k(pcm16x8);

      // base64 encode
      var base64audio = base64Encode(pcm16x16);

      // set the data into the realtime input map before serializing
      // TODO can't I just cache the last little map and set it there at least?
      _realtimeInputMap['realtimeInput']['mediaChunks'][0]['data'] = base64audio;

      // send audio data to websocket
      _channel!.sink.add(jsonEncode(_realtimeInputMap));
    }
  }

  /// Play the audio from the selected recording
  Future<void> _playAudio(Uint8List audioBytes) async {
    if (!_player.isPlaying) {
      await _player.play();
    }

    if (_player.isPlaying) {
      await _player.feed(Uint8List.fromList(audioBytes));
    }
  }

  /// Cancel the playing of the selected recording
  Future<void> _stopAudio() async {
    //if (_player.isPlaying) {
      await _player.stop();
    //}
  }

  /// When we receive a tap to stop the conversation, cancel the audio streaming from Frame,
  /// which will send "final chunk" message, which will close the audio stream
  /// and the Gemini conversation needs to stop too
  Future<void> _stopConversation() async {
    _conversing = false;

    // stop audio playback
    _stopAudio();

    // tell Frame to stop streaming audio
    await frame!.sendMessage(TxCode(msgCode: 0x30, value: 0));
    _streaming = false;

    // stop openai from producing anymore content
    _channel?.sink.close();

    // rxAudio.detach() to close/flush the controller controlling our audio stream
    _rxAudio.detach();

    _appendEvent('Ending conversation');
  }

  /// puts some text into our scrolling log in the UI
  void _appendEvent(String evt) {
    setState(() {
      _eventLog.add(evt);
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_eventLogController.hasClients) {
        _eventLogController.animateTo(
          _eventLogController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    startForegroundService();
    return WithForegroundTask(
      child: MaterialApp(
        title: 'Frame Realtime Gemini Voice and Vision',
        theme: ThemeData.dark(),
        home: Scaffold(
          appBar: AppBar(
            title: const Text('Frame Realtime Gemini Voice and Vision'),
            actions: [getBatteryWidget()]
          ),
          body: Center(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextField(controller: _apiKeyController, decoration: const InputDecoration(hintText: 'Enter Gemini API Key'),),
                  if (_errorMsg != null) Text(_errorMsg!, style: const TextStyle(backgroundColor: Colors.red)),
                  ElevatedButton(onPressed: _savePrefs, child: const Text('Save')),

                  Expanded(child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Expanded(
                        child: ListView.builder(
                          controller: _eventLogController, // Auto-scroll controller
                          itemCount: _eventLog.length,
                          itemBuilder: (context, index) {
                            return Text(
                              _eventLog[index],
                              style: _textStyle,
                            );
                          },
                        ),
                      ),
                    ],
                  )),
                ],
              ),
            ),
          ),
          floatingActionButton: Stack(
            children: [
              if (_eventLog.isNotEmpty) Positioned(
                bottom: 90,
                right: 20,
                child: FloatingActionButton(
                  onPressed: () {
                    Share.share(_eventLog.join('\n'));
                  },
                  child: const Icon(Icons.share)),
              ),
              Positioned(
                bottom: 20,
                right: 20,
                child: getFloatingActionButtonWidget(const Icon(Icons.mic), const Icon(Icons.mic_off)) ?? Container(),
              ),
            ]
          ),
          persistentFooterButtons: getFooterButtonsWidget(),
        ),
      )
    );
  }
}
