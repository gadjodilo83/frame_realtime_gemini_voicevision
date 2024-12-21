import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:logging/logging.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_frame_app/rx/audio.dart';
import 'package:simple_frame_app/rx/tap.dart';
import 'package:simple_frame_app/tx/code.dart';
import 'package:simple_frame_app/tx/plain_text.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
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

  MainAppState() {
    // filter logging
    hierarchicalLoggingEnabled = true;
    Logger.root.level = Level.INFO;
    Logger('Bluetooth').level = Level.OFF;
    Logger('RxAudio').level = Level.FINE;
    Logger('RxTap').level = Level.FINE;

    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: [${record.loggerName}] ${record.time}: ${record.message}');
    });
  }

  /// realtime voice application members
  final TextEditingController _apiKeyController = TextEditingController();
  // 16-bit linear PCM from Frame mic
  Stream<Uint8List>? _audioSampleStream;
  static const _sampleRate = 8000;

  // tap subscription and audio streaming status
  StreamSubscription<int>? _tapSubs;
  bool _streaming = false;

  // transcription UI display
  final List<String> _eventLog = List.empty(growable: true);
  final ScrollController _eventLogController = ScrollController();
  static const _textStyle = TextStyle(fontSize: 24);
  String? _errorMsg;

  @override
  void initState() {
    super.initState();

    // load up the saved text field data
    _loadPrefs()
      // then kick off the connection to Frame and start the app if possible
      .then((_) => tryScanAndConnectAndStart(andRun: true));
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

  /// This application uses OpenAI's realtime API over WebRTC.
  /// It has a running main loop in this function and also on the Frame (frame_app.lua)
  @override
  Future<void> run() async {
    // validate API key exists at least
    _errorMsg = null;
    if (_apiKeyController.text.isEmpty) {
      setState(() {
        _errorMsg = 'Error: Set value for OpenAI API Key';
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
            if (!_streaming) {
              _streaming = true;
              // show microphone emoji
              await frame!.sendMessage(TxPlainText(msgCode: 0x0b, text: '\u{F0010}'));
              await _startConversation();
            }
            else {
              await _stopConversation();
              _streaming = false;

              // prompt the user to begin tapping
              await frame!.sendMessage(TxPlainText(msgCode: 0x0b, text: 'Double-Tap to resume!'));
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

    // TODO cancel the WebRTC conversation if it's running

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
    //_apiKeyController.text

    // tell Frame to start streaming audio
    await frame!.sendMessage(TxCode(msgCode: 0x30, value: 1));

    try {
      // TODO put this object where I can call on it later to detach()
      var rxAudio = RxAudio(streaming: true);
      // the audio stream from Frame, which needs to be closed() to stop the streaming
      _audioSampleStream = rxAudio.attach(frame!.dataResponse);


      // setState(() {
      //   _transcript.add(event);
      // });
      // _scrollToBottom();

    } catch (e) {
      _log.warning(() => 'Error executing application logic: $e');
    }
  }

  /// When we receive a tap to stop the conversation, cancel the audio streaming from Frame,
  /// which will send "final chunk" message, which will close the audio stream
  /// and the WebRTC conversation needs to stop too
  Future<void> _stopConversation() async {
    // tell Frame to stop streaming audio
    await frame!.sendMessage(TxCode(msgCode: 0x30, value: 0));

    // TODO we should also be able to send
    // rxAudio.detach() to close the controller controlling our audio stream
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
        title: 'Frame Realtime OpenAI Voice',
        theme: ThemeData.dark(),
        home: Scaffold(
          appBar: AppBar(
            title: const Text('Frame Realtime OpenAI Voice'),
            actions: [getBatteryWidget()]
          ),
          body: Center(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextField(controller: _apiKeyController, decoration: const InputDecoration(hintText: 'Enter OpenAI API Key'),),
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
