import 'dart:io';

import 'package:flutter/services.dart';

class RefreshRatePlugin {
  const RefreshRatePlugin._();

  static const MethodChannel _channel = MethodChannel(
    'com.perol.dev/display_mode',
  );

  static Future<Map<String, dynamic>> apply({
    required double refreshRate,
    int preferredModeId = 0,
  }) async {
    if (!Platform.isAndroid) return const {};
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'applyRefreshRate',
      <String, dynamic>{
        'refreshRate': refreshRate,
        'preferredModeId': preferredModeId,
      },
    );
    return result ?? const {};
  }

  static Future<Map<String, dynamic>> diagnostics() async {
    if (!Platform.isAndroid) return const {};
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'getRefreshRateDiagnostics',
    );
    return result ?? const {};
  }
}
