// Text-to-speech (the badge has no speaker, so the phone reads reminders out)
// and speech-to-text (dictate a task or message instead of typing it).
// Both are best-effort: on a platform without the engine they quietly do nothing.

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

class Speech {
  final FlutterTts _tts = FlutterTts();
  final SpeechToText _stt = SpeechToText();
  bool _sttReady = false;

  Future<void> speak(String text, {double rate = 0.5, double pitch = 1.0}) async {
    if (text.trim().isEmpty) return;
    try {
      await _tts.setSpeechRate(rate);
      await _tts.setPitch(pitch);
      await _tts.speak(text);
    } catch (e) {
      debugPrint('TTS failed: $e');
    }
  }

  Future<void> stopSpeaking() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }

  bool get listening => _stt.isListening;

  /// Starts dictation. [onResult] fires as words arrive (final == true on the last one).
  /// Returns false if speech recognition isn't available or the mic permission was refused.
  Future<bool> listen({
    required void Function(String text, bool isFinal) onResult,
    void Function(String status)? onStatus,
    void Function(String error)? onError,
  }) async {
    try {
      if (!_sttReady) {
        _sttReady = await _stt.initialize(onStatus: (s) => onStatus?.call(s), onError: (e) => onError?.call(e.errorMsg));
      }
      if (!_sttReady) return false;
      await _stt.listen(
        onResult: (r) => onResult(r.recognizedWords, r.finalResult),
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
          listenFor: const Duration(seconds: 45),
          pauseFor: const Duration(seconds: 4),
        ),
      );
      return true;
    } catch (e) {
      debugPrint('STT failed: $e');
      return false;
    }
  }

  Future<void> stopListening() async {
    try {
      await _stt.stop();
    } catch (_) {}
  }
}
