import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_speech/endless_streaming_service_v2.dart';
import 'package:google_speech/generated/google/cloud/speech/v2/cloud_speech.pb.dart';
import 'package:google_speech/google_speech.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_frame_app/audio_data_response.dart';
import 'package:simple_frame_app/tap_data_response.dart';
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
  final TextEditingController _serviceAccountJsonController = TextEditingController();
  final TextEditingController _projectIdController = TextEditingController();
  final TextEditingController _languageCodeController = TextEditingController();
  // 16-bit linear PCM from Frame mic
  Stream<Uint8List>? audioSampleStream;
  static const _sampleRate = 8000;

  StreamSubscription<int>? _tapSubs;

  String _partialResult = 'N/A';
  final List<String> _transcript = List.empty(growable: true);
  final ScrollController _transcriptController = ScrollController();
  static const _textStyle = TextStyle(fontSize: 30);

  @override
  void initState() {
    super.initState();

    _loadPrefs();
  }

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
    _transcript.clear();
    if (mounted) setState(() {});

    try {
      // listen for double taps to start transcribing
      _tapSubs?.cancel();
      _tapSubs = tapDataResponse(frame!.dataResponse, const Duration(milliseconds: 300))
        .listen((taps) {
          if (taps >= 2) {
            // clear the display
            frame!.sendMessage(TxPlainText(msgCode: 0x0b, text: ' '));
            _startRecognition();
          }
          // ignore spurious 1-taps
        });

      // let Frame know to subscribe for taps and send them to us
      await frame!.sendMessage(TxCode(msgCode: 0x10, value: 1));

      // prompt the user to begin tapping
      await frame!.sendMessage(TxPlainText(msgCode: 0x0b, text: 'Double-Tap to begin!'));

    } catch (e) {
      _log.fine('Error executing application logic: $e');
      currentState = ApplicationState.ready;
      if (mounted) setState(() {});
    }
  }

  /// Once running(), audio streaming is controlled by taps. But the user can cancel
  /// here as well, whether they are currently streaming audio or not.
  @override
  Future<void> cancel() async {
    setState(() {
      currentState = ApplicationState.canceling;
    });

    // make sure we stop streaming if we are currently
    await frame!.sendMessage(TxCode(msgCode: 0x31));

    // let Frame know to cancel subscription for taps too
    await frame!.sendMessage(TxCode(msgCode: 0x10, value: 0));

    setState(() {
      currentState = ApplicationState.ready;
    });
  }

  /// When we receive a tap to start the transcribing, we need to start
  /// audio streaming on Frame and start streaming recognition on the google speech API end
  Future<void> _startRecognition() async {
    final speechToText = EndlessStreamingServiceV2.viaServiceAccount(
      ServiceAccount.fromString(_serviceAccountJsonController.text),
      projectId: _projectIdController.text,
    );

    final recognitionConfig = _getRecognitionConfig();

    // tell Frame to start streaming audio
    await frame!.sendMessage(TxCode(msgCode: 0x30));

    try {
      // the audio stream from Frame, which needs to be closed() to stop the streaming recognition
      audioSampleStream = audioDataStreamResponse(frame!.dataResponse);

      String prevText = '';

      speechToText.endlessStreamingRecognize(
        StreamingRecognitionConfigV2(
            config: recognitionConfig,
            streamingFeatures: StreamingRecognitionFeatures(interimResults: true)
        ),
        audioSampleStream!,
        restartTime: const Duration(seconds: 60),
        transitionBufferTime: const Duration(seconds: 2)
      );

      // TODO any value in keeping a handle on the StreamSubscription?
      // we stop the recognition stream by stopping the audio stream, not by canceling the subscription
      speechToText.endlessStream.listen((data) async {
        // TODO remove? Too much detail?
        _log.fine('Result: $data');

        // just use the first alternative for now (consider other language alternatives if provided?)
        // and concatenate all the pieces (regardless of stability or whether this result(s) is final or not)
        final currentText =
            data.results.where((e) => e.alternatives.isNotEmpty)
            .map((e) => e.alternatives.first.transcript)
            .join();

        if (_log.isLoggable(Level.FINE)) {
          _log.fine('Recognized text: $currentText');
        }

        // if the current text is different from the previous text, send an update to Frame
        // (there are many responses that split in different places, have different stability values,
        // but concatenate to the same string in our case)
        if (currentText != prevText) { // TODO (and Latin script?)
          // Frame can display N lines of plain text, so work out the text wrapping then send
          // the bottom N lines to the display
          // TODO TextUtil wrap, sublist, join
          // TODO change wrapText to return a List of Strings
          String wrappedText = TextUtils.wrapText(currentText, 640, 4);

          // TODO join the last N lines with '\n' for display

          await frame!.sendMessage(TxPlainText(msgCode: 0x0b, text: wrappedText));
        }

        // When a complete utterance is detected, isFinal is set and we can append
        // the utterance to the final transcript.
        // In between, there are non-final fragments, and they can be shown as previews but not appended
        // to the final transcript. A newline doesn't need to be added either.
        if (data.results.first.isFinal) {
          // data.results.first.alternatives.first.transcript should match currentText
          // (the complete utterance) when isFinal is true
          assert(currentText == data.results.first.alternatives.first.transcript);

          // add currentText to the official transcript and clear out the interim
          setState(() {
            _transcript.add(currentText);
            _partialResult = '';
          });
          _scrollToBottom();

        } else {
          // interim results, show the interim result but don't add to the official transcript yet
          setState(() {
            _partialResult = currentText;
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

  /// When we receive a tap to stop transcribing, cancel the audio streaming from Frame,
  /// close the audio stream (and the streaming recognizer connection should stop too)
  Future<void> _stopRecognition() async {
    // tell Frame to stop streaming audio
    await frame!.sendMessage(TxCode(msgCode: 0x31));

    // TODO is this enough to close the stream? I don't think so.
    // Also do stream.close(), maybe drain() it too to stop it right now. Can I do that from this thread?
    await audioSampleStream!.drain();

    // currentState gets set to ApplicationState.ready in listen's onDone()
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_transcriptController.hasClients) {
        _transcriptController.animateTo(
          _transcriptController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
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
                    SizedBox(
                      height: 200,
                      child: ListView.builder(
                        controller: _transcriptController, // Auto-scroll controller
                        itemCount: _transcript.length,
                        itemBuilder: (context, index) {
                          return Text(
                            _transcript[index],
                            style: _textStyle,
                          );
                        },
                      ),
                    ),
                    const Divider(),
                    Align(alignment: Alignment.centerLeft,
                      child: Text('Partial: $_partialResult', style: _textStyle)
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
