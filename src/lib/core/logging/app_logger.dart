import 'package:flutter/foundation.dart';

/// Minimal structured logger. Never log transcripts, full prompts, API keys,
/// or tokens (architecture §12).
abstract final class Log {
  static void d(String message, [Object? extra]) =>
      debugPrint('[app] $message${extra == null ? '' : ' $extra'}');

  static void e(String message, [Object? error, StackTrace? stack]) {
    debugPrint('[app][error] $message');
    if (error != null) debugPrint('[app][error] $error');
    if (stack != null) debugPrint('[app][error] $stack');
  }
}
