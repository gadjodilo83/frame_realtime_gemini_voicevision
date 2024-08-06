import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:buffered_list_stream/buffered_list_stream.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:record/record.dart';
import 'package:vosk_flutter/vosk_flutter.dart';

import 'display_helper.dart';
import 'simple_frame_app.dart';

void main() => runApp(const MainApp());

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  MainAppState createState() => MainAppState();
}

/// SimpleFrameAppState mixin helps to manage the lifecycle of the Frame connection outside of this file
class MainAppState extends State<MainApp> with SimpleFrameAppState {

  MainAppState() {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: ${record.time}: ${record.message}');
    });
  }

  /// speech to text application members
  static const _textStyle = TextStyle(fontSize: 30);
  static const _modelName = 'vosk-model-small-en-us-0.15.zip';
  static const _sampleRate = 16000;

  final _vosk = VoskFlutterPlugin.instance();
  final _recorder = AudioRecorder();
  Stream<List<int>>? _audioSampleBufferedStream;

  Model? _model;
  Recognizer? _recognizer;
  String _partialResult = "N/A";
  String _finalResult = "N/A";

  @override
  void initState() {
    super.initState();
    _initVosk();
  }

  @override
  void dispose() async {
    await _recorder.cancel();
    _recorder.dispose();
    _model?.dispose();
    _recognizer?.dispose();
    super.dispose();
  }

  void _initVosk() async {
    final enSmallModelPath = await ModelLoader().loadFromAssets('assets/$_modelName');
    final model = await _vosk.createModel(enSmallModelPath);
    _recognizer = await _vosk.createRecognizer(model: model, sampleRate: _sampleRate);
    setState(() => _model = model);
  }

  Future<bool> _startAudio() async {
    // Check and request permission if needed
    if (await _recorder.hasPermission()) {
      // start the audio stream
      final recordStream = await _recorder.startStream(
        const RecordConfig(encoder: AudioEncoder.pcm16bits,
          numChannels: 1,
          sampleRate: _sampleRate));

      // buffer the audio stream into chunks of 2048 samples
      _audioSampleBufferedStream = bufferedListStream(
        recordStream.map((event) {
          return event.toList();
        }),
        // samples are PCM16, so 2 bytes per sample
        4096 * 2,
      );

      return true;
    }
    return false;
  }

  void _stopAudio() async {
    await _recorder.cancel();
  }

  /// This application uses vosk speech-to-text to listen to audio from the host mic, convert to text,
  /// and send the text to the Frame in real-time
  @override
  Future<void> runApplication() async {
    currentState = ApplicationState.running;
    if (mounted) setState(() {});

    try {
      if (await _startAudio()) {

        // loop over the incoming audio data and send reults to Frame
        await for (var audioSample in _audioSampleBufferedStream!) {
          if (_recognizer != null) {
            // if the user has clicked Stop we want to stop processing
            // and clear the display
            if (currentState != ApplicationState.running) {
              DisplayHelper.clear(connectedDevice!);
              break;
            }

            final resultReady = await _recognizer!.acceptWaveformBytes(Uint8List.fromList(audioSample));

            if (resultReady) {
              var result = await _recognizer!.getResult();

              var text = jsonDecode(result)['text'];
              _log.fine('Recognized text: $text');

              try {
                DisplayHelper.writeText(connectedDevice!, text);
                DisplayHelper.show(connectedDevice!);
              }
              catch (e) {
                _log.fine('Error sending text to Frame: $e');
              }
              setState(() => _finalResult = text);
            }
            else {
              var result = await _recognizer!.getPartialResult();

              var text = jsonDecode(result)['partial'];

              // Partials are often empty strings so don't bother sending them
              if (text != null && text != '') {
                _log.fine('Partial text: $text');
                try {
                  DisplayHelper.writeText(connectedDevice!, text);
                  DisplayHelper.show(connectedDevice!);
                }
                catch (e) {
                  _log.fine('Error sending text to Frame: $e');
                }
              }
              setState(() => _partialResult = text);
            }
          }
        }

      _stopAudio();
      }
    } catch (e) {
      _log.fine('Error executing application logic: $e');
    }

    currentState = ApplicationState.ready;
    if (mounted) setState(() {});
  }

  @override
  Future<void> stopApplication() async {
    currentState = ApplicationState.stopping;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // work out the states of the footer buttons based on the app state
    List<Widget> pfb = [];

    switch (currentState) {
      case ApplicationState.disconnected:
        pfb.add(TextButton(onPressed: scanOrReconnectFrame, child: const Text('Connect Frame')));
        pfb.add(const TextButton(onPressed: null, child: Text('Start Speech-to-Text')));
        pfb.add(const TextButton(onPressed: null, child: Text('Finish')));
        break;

      case ApplicationState.scanning:
      case ApplicationState.connecting:
      case ApplicationState.disconnecting:
      case ApplicationState.stopping:
        pfb.add(const TextButton(onPressed: null, child: Text('Connect Frame')));
        pfb.add(const TextButton(onPressed: null, child: Text('Start Speech-to-Text')));
        pfb.add(const TextButton(onPressed: null, child: Text('Finish')));
        break;

      case ApplicationState.ready:
        pfb.add(const TextButton(onPressed: null, child: Text('Connect Frame')));
        pfb.add(TextButton(onPressed: runApplication, child: const Text('Start Speech-to-Text')));
        pfb.add(TextButton(onPressed: disconnectFrame, child: const Text('Finish')));
        break;

      case ApplicationState.running:
        pfb.add(const TextButton(onPressed: null, child: Text('Connect Frame')));
        pfb.add(TextButton(onPressed: stopApplication, child: const Text('Stop Speech-to-Text')));
        pfb.add(const TextButton(onPressed: null, child: Text('Finish')));
        break;
    }

    return MaterialApp(
      title: 'Speech-to-Text',
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text("Frame Speech-to-Text"),
        ),
        body: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Align(alignment: Alignment.centerLeft,
                  child: Text('Partial: $_partialResult', style: _textStyle)
                ),
                const Divider(),
                Align(alignment: Alignment.centerLeft,
                  child: Text('Final: $_finalResult', style: _textStyle)
                ),
              ],
            ),
          ),
        ),
        persistentFooterButtons: pfb,
      ),
    );
  }
}
