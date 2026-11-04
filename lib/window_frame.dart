import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

const _windowFrameKey = 'mainWindowFrame';

Future<void> restoreWindowFrame() async {
  final preferences = await SharedPreferences.getInstance();
  final values = preferences
      .getString(_windowFrameKey)
      ?.split(',')
      .map(double.tryParse)
      .toList();
  if (values != null && values.length == 4 && !values.contains(null)) {
    try {
      await windowManager.setBounds(
        Rect.fromLTWH(values[0]!, values[1]!, values[2]!, values[3]!),
      );
    } catch (_) {
      await windowManager.center();
    }
  } else {
    await windowManager.center();
  }
  windowManager.addListener(_WindowFrameListener(preferences));
}

class _WindowFrameListener with WindowListener {
  _WindowFrameListener(this.preferences);

  final SharedPreferences preferences;
  var _saving = false;
  var _pending = false;

  void _schedule() {
    if (_saving) {
      _pending = true;
      return;
    }
    _saving = true;
    unawaited(
      _save().whenComplete(() {
        _saving = false;
        if (_pending) {
          _pending = false;
          _schedule();
        }
      }),
    );
  }

  Future<void> _save() async {
    if (await windowManager.isFullScreen() ||
        await windowManager.isMaximized() ||
        await windowManager.isMinimized()) {
      return;
    }
    final bounds = await windowManager.getBounds();
    if (!bounds.left.isFinite ||
        !bounds.top.isFinite ||
        !bounds.width.isFinite ||
        !bounds.height.isFinite ||
        bounds.width <= 0 ||
        bounds.height <= 0) {
      return;
    }
    await preferences.setString(
      _windowFrameKey,
      [bounds.left, bounds.top, bounds.width, bounds.height].join(','),
    );
  }

  @override
  void onWindowMoved() => _schedule();

  @override
  void onWindowResized() => _schedule();

  @override
  void onWindowUnmaximize() => _schedule();

  @override
  void onWindowClose() => _schedule();
}
