import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:frame_realtime_gemini_voicevision/audio_upsampler.dart';
import 'package:frame_realtime_gemini_voicevision/gemini_realtime.dart';
import 'package:logging/logging.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:frame_msg/rx/audio.dart';
import 'package:frame_msg/rx/tap.dart';
import 'package:frame_msg/tx/capture_settings.dart';
import 'package:frame_msg/tx/code.dart';
import 'package:frame_msg/tx/plain_text.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'foreground_service.dart';

void main() {
  initializeForegroundService();
  fbp.FlutterBluePlus.setLogLevel(fbp.LogLevel.info);
  runApp(const MainApp());
}

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});
  @override
  MainAppState createState() => MainAppState();
}

class MainAppState extends State<MainApp> with SimpleFrameAppState {
  static const int maxFrameLines = 4;
  static const int maxFrameLineLength = 32;
  List<String> _frameLines = [];
  String _currentLine = '';


  final List<String> _languages = [
    "German", "English", "Italian", "Spanish", "French",
  ];
  final Map<String, String> _languageMap = {
    "German": "German",
    "English": "English",
    "Italian": "Italian",
    "Spanish": "Spanish",
    "French": "French",
  };
  String _inputLanguage = "German";
  String _outputLanguage = "Italian";

  late final GeminiRealtime _gemini;
  GeminiVoiceName _voiceName = GeminiVoiceName.none;
  bool _playingAudio = false;
  bool _streaming = false;
  StreamSubscription<int>? _tapSubs;
  final RxAudio _rxAudio = RxAudio(streaming: true);
  StreamSubscription<Uint8List>? _frameAudioSubs;
  Stream<Uint8List>? _frameAudioSampleStream;

  final _apiKeyController = TextEditingController();
  final _eventLog = <String>[];
  final _eventLogController = ScrollController();
  static const _textStyle = TextStyle(fontSize: 20);
  String? _errorMsg;

  MainAppState() {
    hierarchicalLoggingEnabled = true;
    Logger.root.level = Level.FINE;
    Logger('Bluetooth').level = Level.FINE;
    Logger('RxAudio').level = Level.FINE;
    Logger('RxTap').level = Level.FINE;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: [${record.loggerName}] ${record.time}: ${record.message}');
    });

    _gemini = GeminiRealtime(
      _audioReadyCallback,
      _appendEvent,
      textCallback: _onGeminiText,
    );
  }

  /// Optimale Anzeige für das Frame-Display:
  /// - Zeilenumbruch bei max. 32 Zeichen
  /// - Leerschläge korrekt, keine doppelten Zeilen
  /// - Automatisches Scrolling (max. 5 Zeilen sichtbar)
void _onGeminiText(String text) async {
  // 1. Entferne CRLF, ersetze durch LF
  text = text.replaceAll('\r\n', '\n');

  // 2. Splitte den Input falls mehrere Zeilenumbrüche in einem Fragment kommen
  List<String> parts = text.split('\n');

  for (int i = 0; i < parts.length; i++) {
    String fragment = parts[i];

    // (a) Leeres Fragment nach \n? => Nur Zeile abschließen
    if (fragment.trim().isEmpty) {
      if (_currentLine.trim().isNotEmpty) {
        _frameLines.add(_currentLine.trimRight());
        _currentLine = '';
      }
      continue;
    }

    // (b) Text an die aktuelle Zeile anfügen
    if (_currentLine.isNotEmpty && !_currentLine.endsWith(' ') && !fragment.startsWith(' ')) {
      _currentLine += ' ';
    }
    _currentLine += fragment;

    // (c) Zeilenumbruch bei maxFrameLineLength Zeichen
    while (_currentLine.length > maxFrameLineLength) {
      _frameLines.add(_currentLine.substring(0, maxFrameLineLength));
      _currentLine = _currentLine.substring(maxFrameLineLength);
    }

    // (d) Nach jeder Teilzeile (außer der letzten) abschließen
    if (i < parts.length - 1) {
      if (_currentLine.trim().isNotEmpty) {
        _frameLines.add(_currentLine.trimRight());
        _currentLine = '';
      }
    }
  }

  // 3. Immer aktuelle Zeile als letzte Zeile anzeigen (falls noch offen)
  final displayLines = List<String>.from(_frameLines);
  if (_currentLine.trim().isNotEmpty) displayLines.add(_currentLine);

  // 4. Maximal 5 Zeilen anzeigen (Scrolling)
  final visibleLines = displayLines.length > maxFrameLines
      ? displayLines.sublist(displayLines.length - maxFrameLines)
      : displayLines;

  final displayText = visibleLines.join('\n');
  if (frame != null) {
    await frame!.sendMessage(0x0b, TxPlainText(text: displayText).pack());
  }
  _appendEvent("Übersetzung: $displayText");
}


  @override
  void initState() {
    super.initState();
    _asyncInit();
  }

  Future<void> _asyncInit() async {
    await _loadPrefs();
    const sampleRate = 24000;
    FlutterPcmSound.setLogLevel(LogLevel.error);
    await FlutterPcmSound.setup(sampleRate: sampleRate, channelCount: 1);
    FlutterPcmSound.setFeedThreshold(sampleRate ~/ 30);
    FlutterPcmSound.setFeedCallback(_onFeed);
  }

  void _onFeed(int remainingFrames) async {
    if (remainingFrames < 2000) {
      if (_gemini.hasResponseAudio()) {
        await FlutterPcmSound.feed(PcmArrayInt16(bytes: _gemini.getResponseAudioByteData()));
      } else {
        _log.fine('Response audio ended');
        _playingAudio = false;
      }
    }
  }

  @override
  Future<void> dispose() async {
    await _gemini.disconnect();
    await _frameAudioSubs?.cancel();
    await FlutterPcmSound.release();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _apiKeyController.text = prefs.getString('api_key') ?? '';
      _voiceName = GeminiVoiceName.values.firstWhere(
        (e) => e.toString().split('.').last == (prefs.getString('voice_name') ?? 'none'),
        orElse: () => GeminiVoiceName.none,
      );
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_key', _apiKeyController.text);
    await prefs.setString('voice_name', _voiceName.name);
  }

  String _buildGeminiPrompt(String input, String output) {
    return 'You act as a real-time translator and translate everything you hear from '
        '"${_languageMap[input]}" into "${_languageMap[output]}". '
        'Output only the translation, no explanation, no preface.';
  }

  @override
  Future<void> run() async {
    _errorMsg = null;
    if (_apiKeyController.text.isEmpty) {
      setState(() {
        _errorMsg = 'Error: Set value for Gemini API Key';
      });
      return;
    }
    final systemPrompt = _buildGeminiPrompt(_inputLanguage, _outputLanguage);
    await _gemini.connect(_apiKeyController.text, _voiceName, systemPrompt);

    if (!_gemini.isConnected()) {
      _log.severe('Connection to Gemini failed');
      return;
    }
    setState(() { currentState = ApplicationState.running; });

    try {
      _tapSubs?.cancel();
      _tapSubs = RxTap().attach(frame!.dataResponse)
        .listen((taps) async {
          _log.info('taps: $taps');
          if (_gemini.isConnected()) {
            if (taps >= 2) {
              if (!_streaming) {
                await _startFrameStreaming();
                await frame!.sendMessage(0x0b, TxPlainText(text: '\u{F0010}').pack());
              } else {
                await _stopFrameStreaming();
                await frame!.sendMessage(0x0b, TxPlainText(text: 'Double-Tap to resume!').pack());
              }
            }
          } else {
            _appendEvent('Disconnected from Gemini');
            _stopFrameStreaming();
            setState(() {
              currentState = ApplicationState.ready;
            });
          }
        });

      await frame!.sendMessage(0x10, TxCode(value: 1).pack());
      await frame!.sendMessage(0x0b, TxPlainText(text: 'Double-Tap to begin!').pack());
    } catch (e) {
      _errorMsg = 'Error executing application logic: $e';
      _log.fine(_errorMsg);
      setState(() {
        currentState = ApplicationState.ready;
      });
    }
  }

  @override
  Future<void> cancel() async {
    setState(() { currentState = ApplicationState.canceling; });
    _tapSubs?.cancel();
    if (_streaming) _stopFrameStreaming();
    await frame!.sendMessage(0x30, TxCode(value: 0).pack());
    await frame!.sendMessage(0x10, TxCode(value: 0).pack());
    await frame!.sendMessage(0x0b, TxPlainText(text: ' ').pack());
    await _gemini.disconnect();
    setState(() { currentState = ApplicationState.ready; });
  }

  Future<void> _startFrameStreaming() async {
    _currentLine = '';
    _frameLines.clear();
    _appendEvent('Starting Frame Streaming');
    FlutterPcmSound.start();
    _streaming = true;
    try {
      _frameAudioSampleStream = _rxAudio.attach(frame!.dataResponse);
      _frameAudioSubs?.cancel();
      _frameAudioSubs = _frameAudioSampleStream!.listen(_handleFrameAudio);
      await frame!.sendMessage(0x30, TxCode(value: 1).pack());
    } catch (e) {
      _log.warning(() => 'Error executing application logic: $e');
    }
  }

  Future<void> _stopFrameStreaming() async {
    _currentLine = '';
    _frameLines.clear();
    _streaming = false;
    _gemini.stopResponseAudio();
    await frame!.sendMessage(0x30, TxCode(value: 0).pack());
    _rxAudio.detach();
    _appendEvent('Ending Frame Streaming');
  }

  void _handleFrameAudio(Uint8List pcm16x8) {
    if (_gemini.isConnected()) {
      var pcm16x16 = AudioUpsampler.upsample8kTo16k(pcm16x8);
      _gemini.sendAudio(pcm16x16);
    }
  }

  void _audioReadyCallback() {
    if (!_playingAudio) {
      _playingAudio = true;
      _onFeed(0);
      _log.fine('Response audio started');
    }
  }

  void _appendEvent(String evt) {
    setState(() { _eventLog.add(evt); });
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
        title: 'Frame Realtime Gemini Voice Translator',
        theme: ThemeData.dark(),
        home: Scaffold(
          appBar: AppBar(
            title: const Text('Frame Realtime Gemini Voice Translator'),
            actions: [getBatteryWidget()],
          ),
          body: Center(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _apiKeyController,
                          decoration: const InputDecoration(hintText: 'Enter Gemini API Key'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      DropdownButton<GeminiVoiceName>(
                        value: _voiceName,
                        onChanged: (GeminiVoiceName? newValue) {
                          setState(() { _voiceName = newValue!; });
                        },
                        items: GeminiVoiceName.values.map<DropdownMenuItem<GeminiVoiceName>>((GeminiVoiceName value) {
                          return DropdownMenuItem<GeminiVoiceName>(
                            value: value,
                            child: Text(value.toString().split('.').last),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButton<String>(
                          value: _inputLanguage,
                          onChanged: (value) => setState(() => _inputLanguage = value!),
                          items: _languages
                              .map((lang) => DropdownMenuItem(
                                    value: lang,
                                    child: Text(lang),
                                  ))
                              .toList(),
                        ),
                      ),
                      const Icon(Icons.arrow_forward),
                      Expanded(
                        child: DropdownButton<String>(
                          value: _outputLanguage,
                          onChanged: (value) => setState(() => _outputLanguage = value!),
                          items: _languages
                              .map((lang) => DropdownMenuItem(
                                    value: lang,
                                    child: Text(lang),
                                  ))
                              .toList(),
                        ),
                      ),
                    ],
                  ),
                  if (_errorMsg != null)
                    Text(_errorMsg!, style: const TextStyle(backgroundColor: Colors.red)),
                  ElevatedButton(onPressed: _savePrefs, child: const Text('Save')),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10.0),
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.bluetooth_searching),
                      label: const Text("Connect with Frame"),
                      onPressed: () => tryScanAndConnectAndStart(andRun: true),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Expanded(
                          child: ListView.builder(
                            controller: _eventLogController,
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
                    ),
                  ),
                ],
              ),
            ),
          ),
          floatingActionButton: Stack(
            children: [
              if (_eventLog.isNotEmpty)
                Positioned(
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
            ],
          ),
          persistentFooterButtons: getFooterButtonsWidget(),
        ),
      ),
    );
  }
}
