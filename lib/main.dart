import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_speech/endless_streaming_service_v2.dart';
import 'package:google_speech/generated/google/cloud/speech/v2/cloud_speech.pb.dart';
import 'package:google_speech/google_speech.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_frame_app/audio_data_response.dart';
import 'package:simple_frame_app/tx/code.dart';
import 'package:simple_frame_app/tx/plain_text.dart';
import 'package:simple_frame_app/text_utils.dart';
import 'package:simple_frame_app/simple_frame_app.dart';

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
    Logger.root.level = Level.FINER;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: [${record.loggerName}] ${record.time}: ${record.message}');
    });
  }

  /// speech to text application members
  static const _sampleRate = 8000;
  final TextEditingController _serviceAccountJsonController = TextEditingController();
  final TextEditingController _projectIdController = TextEditingController();
  final TextEditingController _languageCodeController = TextEditingController();

  String _partialResult = 'N/A';
  String _finalResult = 'N/A';
  static const _textStyle = TextStyle(fontSize: 30);

  @override
  void initState() {
    super.initState();

    _loadPrefs();
  }

  RecognitionConfigV2 _getRecognitionConfig() => RecognitionConfigV2(
    model: RecognitionModelV2.telephony, // TODO try .long, .telephony (for self vs others' speech)
    languageCodes: [_languageCodeController.text], // TODO try multi-codes e.g. ['de-DE', 'en-US'], what does it mean to have more in the list, it seemed to only use German
    features: RecognitionFeatures(),
    explicitDecodingConfig: ExplicitDecodingConfig(
      encoding: ExplicitDecodingConfig_AudioEncoding.LINEAR16,
      sampleRateHertz: _sampleRate,
      audioChannelCount: 1,
    )
  );

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _serviceAccountJsonController.text = prefs.getString('service_account_json') ?? '';
      _projectIdController.text = prefs.getString('project_id') ?? '';
      _languageCodeController.text = prefs.getString('language_code') ?? '';
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString('service_account_json', _serviceAccountJsonController.text);
    await prefs.setString('project_id', _projectIdController.text);
    await prefs.setString('language_code', _languageCodeController.text);
  }


  /// This application uses google cloud speech-to-text to listen to audio from the Frame mic, convert to text,
  /// and send the text to the Frame in real-time. It has a running main loop in this function
  /// and also on the Frame (frame_app.lua)
  @override
  Future<void> run() async {
    if (_serviceAccountJsonController.text.isEmpty || _projectIdController.text.isEmpty || _languageCodeController.text.isEmpty) {
      _log.fine('Set values for service account, project id and language code'); // TODO Toast?
      return;
    }

    currentState = ApplicationState.running;
    _partialResult = '';
    _finalResult = '';
    if (mounted) setState(() {});

    final speechToText = EndlessStreamingServiceV2.viaServiceAccount(
      ServiceAccount.fromString(_serviceAccountJsonController.text),
      projectId: _projectIdController.text,
    );

    final recognitionConfig = _getRecognitionConfig();

    // tell Frame to start streaming audio
    await frame!.sendMessage(TxCode(msgCode: 0x30));

    try {
      // TODO do I need to keep a reference to this stream outside run()
      // so I can inject no audio data bytes (how? stream.add(Uint8List(0)?)) maybe drain()
      // the remaining stream and close it when the user taps to stop streaming?
      var audioSampleStream = audioDataStreamResponse(frame!.dataResponse);

      String responseText = '';
      String prevText = '';

      speechToText.endlessStreamingRecognize(
        StreamingRecognitionConfigV2(
            config: recognitionConfig,
            streamingFeatures: StreamingRecognitionFeatures(interimResults: true)
        ),
        audioSampleStream,
        restartTime: const Duration(seconds: 60),
        transitionBufferTime: const Duration(seconds: 2)
      );

      // TODO any value in keeping a handle on the StreamSubscription?
      // we stop the recognition stream by stopping the audio stream, not by canceling the subscription
      speechToText.endlessStream.listen((data) async {
        // TODO remove? Too much detail?
        _log.finer('Result: $data');

        // just look at the first alternative for now (consider other language alternatives if provided?)
        final currentText =
            data.results.where((e) => e.alternatives.isNotEmpty)
            .map((e) => e.alternatives.first.transcript)
            .join('\n');

        if (_log.isLoggable(Level.FINE)) {
          _log.fine('Recognized text: $currentText');
        }

        // send current text to Frame (only if it's different to what's on there already)
        if (currentText != prevText) {
          String wrappedText = TextUtils.wrapText(currentText, 640, 4);
          await frame!.sendMessage(TxPlainText(msgCode: 0x0b, text: wrappedText));
          prevText = currentText;
        }

        // TODO does it ever change its mind? This seems to append without rewriting any previous partial results
        if (data.results.first.isFinal) {
          responseText += '\n$currentText';
          setState(() {
            _finalResult = responseText;
            _partialResult = '';
          });
        } else {
          setState(() {
            _partialResult = '$responseText\n$currentText';
            _finalResult = '';
          });
        }
      }, onDone: () {
        // audio stream was stopped so Recognizer stream stopped
        setState(() {
          currentState = ApplicationState.ready;
        });
      });

    } catch (e) {
      _log.fine('Error executing application logic: $e');
    }
  }

  /// The run() function will keep running until we interrupt it here
  /// and it will stop listening to audio
  @override
  Future<void> cancel() async {
    setState(() {
      currentState = ApplicationState.canceling;
    });

    // tell Frame to stop streaming audio
    await frame!.sendMessage(TxCode(msgCode: 0x31));

    // currentState gets set to ApplicationState.ready in listen's onDone()
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Transcribe - Google Cloud Speech',
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Transcribe - Google Cloud Speech'),
          actions: [getBatteryWidget()]
        ),
        body: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextField(controller: _serviceAccountJsonController, obscureText: true, decoration: const InputDecoration(hintText: 'Enter Service Account JSON'),),
                TextField(controller: _projectIdController, obscureText: false, decoration: const InputDecoration(hintText: 'Enter Project Id'),),
                TextField(controller: _languageCodeController, obscureText: false, decoration: const InputDecoration(hintText: 'Enter Language Code e.g. en-US'),),
                ElevatedButton(onPressed: _savePrefs, child: const Text('Save')),

                Expanded(child: Column(
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
                )),
              ],
            ),
          ),
        ),
        floatingActionButton: getFloatingActionButtonWidget(const Icon(Icons.mic), const Icon(Icons.mic_off)),
        persistentFooterButtons: getFooterButtonsWidget(),
      ),
    );
  }
}
