import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'audio_data_extractor.dart';

enum GeminiVoiceName { none, Puck, Charon, Kore, Fenrir, Aoede, Leda, Orus, Zephyr }

class GeminiRealtime {
  final _log = Logger("Gem");
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSubs;
  bool _connected = false;

  final void Function(String)? textCallback;
  final Function(String) eventLogger;
  final Function() audioReadyCallback;

  // Default setupMap – wird im connect() dynamisch angepasst!
  final Map<String, dynamic> _setupMap = {
    'setup': {
      'model': 'models/gemini-2.0-flash-live-001',
      'generation_config': {
        'response_modalities': 'audio', // wird dynamisch auf 'text' gesetzt
        'speech_config': {
          'voice_config': {
            'prebuilt_voice_config': {'voice_name': 'Puck'}
          }
        }
      },
      'system_instruction': {'parts': [{'text': ''}]}
    }
  };
  final Map<String, dynamic> _realtimeAudioInputMap = {
    'realtimeInput': {
      'mediaChunks': [
        {'mimeType': 'audio/pcm;rate=16000', 'data': ''}
      ]
    }
  };
  final Map<String, dynamic> _realtimeImageInputMap = {
    'realtimeInput': {
      'mediaChunks': [
        {'mimeType': 'image/jpeg', 'data': ''}
      ]
    }
  };

  // audio buffer
  final _audioBuffer = ListQueue<Uint8List>();

  GeminiRealtime(
    this.audioReadyCallback,
    this.eventLogger,
    {this.textCallback}
  );

  /// Returns the current state of the Gemini connection
  bool isConnected() => _connected;

  /// Connect to Gemini Live and set up the websocket connection using the specified API key
  Future<bool> connect(String apiKey, GeminiVoiceName voice, String systemInstruction) async {
    eventLogger('Connecting to Gemini');
    _log.info('Connecting to Gemini');

    // --- Dynamisch: Keine Sprachausgabe oder Voice ---
    if (voice == GeminiVoiceName.none) {
      _setupMap['setup']['generation_config'].remove('speech_config');
      _setupMap['setup']['generation_config']['response_modalities'] = 'text';
    } else {
      _setupMap['setup']['generation_config']['response_modalities'] = 'audio';
      _setupMap['setup']['generation_config']['speech_config'] = {
        'voice_config': {
          'prebuilt_voice_config': {'voice_name': voice.name}
        }
      };
    }

    _setupMap['setup']['system_instruction']['parts'][0]['text'] = systemInstruction;
    _audioBuffer.clear();

    await _channel?.sink.close();
    _channel = WebSocketChannel.connect(Uri.parse(
      'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent?key=$apiKey'
    ));

    await _channel!.ready;
    _channelSubs = _channel!.stream.listen(_handleGeminiEvent);
    _log.info(_setupMap);
    _channel!.sink.add(jsonEncode(_setupMap));

    _connected = true;
    eventLogger('Connected');
    return _connected;
  }

  /// Disconnect from Gemini Live by closing the websocket connection
  Future<void> disconnect() async {
    eventLogger('Disconnecting from Gemini');
    _log.info('Disconnecting from Gemini');
    _connected = false;
    await _channelSubs?.cancel();
    await _channel?.sink.close();
  }

  /// Sends the audio to Gemini - bytes should be provided as PCM16 samples at 16kHz
  void sendAudio(Uint8List pcm16x16) {
    if (!_connected) {
      eventLogger('App trying to send audio when disconnected');
      return;
    }
    var base64audio = base64Encode(pcm16x16);
    _realtimeAudioInputMap['realtimeInput']['mediaChunks'][0]['data'] = base64audio;
    _channel!.sink.add(jsonEncode(_realtimeAudioInputMap));
  }

  /// Send the photo to Gemini, encoded as jpeg
  void sendPhoto(Uint8List jpegBytes) {
    if (!_connected) {
      eventLogger('App trying to send a photo when disconnected');
      return;
    }
    var base64image = base64Encode(jpegBytes);
    _realtimeImageInputMap['realtimeInput']['mediaChunks'][0]['data'] = base64image;
    _log.info('sending photo');
    _channel!.sink.add(jsonEncode(_realtimeImageInputMap));
  }

  bool hasResponseAudio() => _audioBuffer.isNotEmpty;

  ByteData getResponseAudioByteData() {
    if (hasResponseAudio()) {
      return (_audioBuffer.removeFirst()).buffer.asByteData();
    } else {
      return ByteData(0);
    }
  }

  void stopResponseAudio() {
    _audioBuffer.clear();
  }

  /// handle the Gemini server events that come through the websocket
  FutureOr<void> _handleGeminiEvent(dynamic eventJson) async {
    String eventString = utf8.decode(eventJson);
    _log.info('Gemini RAW EVENT: $eventString');
    var event = jsonDecode(eventString);

    // Audio-Handling (wie gehabt)
    var audioData = AudioDataExtractor.extractAudioData(event);
    if (audioData != null) {
      for (var chunk in audioData) {
        _audioBuffer.add(chunk);
        audioReadyCallback();
      }
    }

    // TEXT-Handling
    String? geminiText;
    var serverContent = event['serverContent'];
    if (serverContent != null) {
      // 1. NEU: modelTurn (neues Gemini API Format!)
      if (serverContent['modelTurn'] != null &&
          serverContent['modelTurn']['parts'] != null &&
          serverContent['modelTurn']['parts'] is List &&
          serverContent['modelTurn']['parts'].isNotEmpty &&
          serverContent['modelTurn']['parts'][0]['text'] != null) {
        geminiText = serverContent['modelTurn']['parts'][0]['text'];
      }
      // 2. ALT: Nur 'parts'
      else if (serverContent['parts'] != null &&
               serverContent['parts'] is List &&
               serverContent['parts'].isNotEmpty &&
               serverContent['parts'][0]['text'] != null) {
        geminiText = serverContent['parts'][0]['text'];
      }
    }
    // 3. Fallback: candidates[0].content.parts[0].text (bei manchen Gemini APIs)
    if (geminiText == null && event['candidates'] != null) {
      try {
        geminiText = event['candidates'][0]['content']['parts'][0]['text'];
      } catch (_) {}
    }

    // d) Callback aufrufen, wenn Text gefunden!
    if (geminiText != null && textCallback != null && geminiText.isNotEmpty) {
      _log.info('Gemini Übersetzungstext: $geminiText');
      textCallback!(geminiText);
    }

    // Logging wie gehabt:
    if (serverContent != null) {
      if (serverContent['interrupted'] != null) {
        _audioBuffer.clear();
        eventLogger('---Interruption---');
        _log.fine('Response interrupted by user');
      } else if (serverContent['turnComplete'] != null) {
        eventLogger('Server turn complete');
      } else {
        eventLogger(serverContent.toString());
      }
    } else if (event['setupComplete'] != null) {
      eventLogger('Setup is complete');
      _log.info('Gemini setup is complete');
    } else {
      _log.info('Unbekanntes Gemini-Event: $eventString');
      eventLogger(eventString);
    }
  }
}
