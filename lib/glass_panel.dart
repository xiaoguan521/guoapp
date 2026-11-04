import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(28)),
    this.sigma = 24,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final double sigma;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .18),
            blurRadius: 18,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: dark
                  ? Colors.black.withValues(alpha: .4)
                  : Colors.white.withValues(alpha: .6),
              borderRadius: borderRadius,
              border: Border.all(
                color: Colors.white.withValues(alpha: dark ? .16 : .85),
                width: 1,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 统一的玻璃对话框外观。整块为不透明底色加高光描边，播放视频等
/// 明暗不断变化的背景上不产生任何闪烁或灰色边缘。
class GlassDialog extends StatelessWidget {
  const GlassDialog({super.key, required this.child, this.maxWidth = 340});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Dialog(
      elevation: 0,
      backgroundColor: dark ? const Color(0xFF16171B) : const Color(0xFFF8F6F5),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(24)),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.all(Radius.circular(24)),
          border: Border.all(
            color: Colors.white.withValues(alpha: dark ? .14 : .9),
          ),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: child,
        ),
      ),
    );
  }
}

/// 统一的玻璃选项选择控件。
class GlassChoiceField<T> extends StatelessWidget {
  const GlassChoiceField({
    super.key,
    required this.value,
    required this.entries,
    required this.onChanged,
    this.label,
    this.enabled = true,
    this.compact = false,
  });

  final T value;
  final String? label;
  final List<(T, String)> entries;
  final ValueChanged<T> onChanged;
  final bool enabled;
  final bool compact;

  String get _current =>
      entries
          .where((entry) => entry.$1 == value)
          .map((entry) => entry.$2)
          .firstOrNull ??
      '';

  Future<void> _open(BuildContext context) async {
    final anchor = glassMenuAnchor(context);
    if (anchor == null) return;
    final selected = await showGlassMenu<T>(
      context: context,
      anchor: anchor,
      autofocusSelected: true,
      entries: [
        for (final (entryValue, entryLabel) in entries)
          GlassMenuEntry(
            value: entryValue,
            label: Text(entryLabel),
            selected: entryValue == value,
          ),
      ],
    );
    if (selected != null && selected != value) onChanged(selected);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textColor = enabled
        ? colors.onSurface
        : colors.onSurface.withValues(alpha: .38);
    final onTap = enabled
        ? () {
            unawaited(_open(context));
          }
        : null;
    if (compact) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (label != null) ...[
                Text(label!, style: TextStyle(color: textColor, fontSize: 13)),
                const SizedBox(width: 6),
              ],
              Text(
                _current,
                style: TextStyle(
                  color: enabled ? colors.primary : textColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Icon(Icons.expand_more_rounded, size: 18, color: textColor),
            ],
          ),
        ),
      );
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: Icon(
            Icons.expand_more_rounded,
            color: enabled
                ? colors.onSurfaceVariant
                : colors.onSurface.withValues(alpha: .38),
          ),
        ),
        child: Text(
          _current,
          style: TextStyle(color: textColor, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class PressScale extends StatefulWidget {
  const PressScale({
    super.key,
    required this.child,
    this.scale = .96,
    this.duration = const Duration(milliseconds: 140),
  });

  final Widget child;
  final double scale;
  final Duration duration;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _pressed = false;

  void _update(bool pressed) {
    if (_pressed == pressed) return;
    setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => _update(true),
    onPointerUp: (_) => _update(false),
    onPointerCancel: (_) => _update(false),
    child: AnimatedScale(
      scale: _pressed ? widget.scale : 1,
      duration: widget.duration,
      curve: Curves.easeOutCubic,
      child: widget.child,
    ),
  );
}

class GlassMenuEntry<T> {
  const GlassMenuEntry({
    required this.value,
    required this.label,
    this.leading,
    this.trailing,
    this.selected = false,
    this.enabled = true,
  });

  final T value;
  final Widget label;
  final Widget? leading;
  final Widget? trailing;
  final bool selected;
  final bool enabled;
}

Rect? glassMenuAnchor(BuildContext context) {
  final object = context.findRenderObject();
  if (object is! RenderBox) return null;
  final overlay = Overlay.of(context).context.findRenderObject();
  if (overlay is! RenderBox) return null;
  return MatrixUtils.transformRect(
    object.getTransformTo(overlay),
    Offset.zero & object.size,
  );
}

double _glassMenuWidth<T>(
  BuildContext context,
  List<GlassMenuEntry<T>> entries,
  double maxWidth,
) {
  final scaler = MediaQuery.textScalerOf(context);
  final fallback = DefaultTextStyle.of(context).style;
  final direction = Directionality.maybeOf(context) ?? TextDirection.ltr;
  var textWidth = 0.0;
  for (final entry in entries) {
    final label = entry.label;
    if (label is! Text) return maxWidth;
    final data = label.data;
    if (data == null || data.isEmpty) continue;
    final painter = TextPainter(
      text: TextSpan(
        text: data,
        style: (label.style ?? fallback).copyWith(
          fontSize: 14,
          fontWeight: entry.selected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      textScaler: scaler,
      textDirection: direction,
    )..layout();
    final width = painter.width;
    painter.dispose();
    if (width > textWidth) textWidth = width;
  }
  final hasLeading = entries.any((entry) => entry.leading != null);
  final hasTrailing = entries.any((entry) => entry.trailing != null);
  final measured =
      textWidth * 1.12 + (hasLeading ? 30 : 0) + (hasTrailing ? 28 : 0) + 40;
  if (measured < 122) return 122;
  return measured > maxWidth ? maxWidth : measured;
}

Future<T?> showGlassMenu<T>({
  required BuildContext context,
  required Rect anchor,
  required List<GlassMenuEntry<T>> entries,
  bool alignRight = false,
  bool autofocusSelected = false,
  double width = 232,
  double maxHeight = 430,
  double itemExtent = 46,
}) => Navigator.of(context).push<T>(
  _GlassMenuRoute<T>(
    anchor: anchor,
    entries: entries,
    alignRight: alignRight,
    autofocusSelected: autofocusSelected,
    width: _glassMenuWidth(context, entries, width),
    maxHeight: maxHeight,
    itemExtent: itemExtent,
  ),
);

class _GlassMenuRoute<T> extends PopupRoute<T> {
  _GlassMenuRoute({
    required this.autofocusSelected,
    required this.anchor,
    required this.entries,
    required this.alignRight,
    required this.width,
    required this.maxHeight,
    required this.itemExtent,
  });

  final Rect anchor;
  final List<GlassMenuEntry<T>> entries;
  final bool alignRight;
  final bool autofocusSelected;
  final double width;
  final double maxHeight;
  final double itemExtent;

  static const _margin = 8.0;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 200);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 110);

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => '关闭菜单';

  double get _height {
    final content = entries.length * itemExtent + 12;
    return content < maxHeight ? content : maxHeight;
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final size = MediaQuery.sizeOf(context);
    final available = size.height - _margin * 2;
    final height = _height > available ? available : _height;
    final menuWidth = width > size.width - 16 ? size.width - 16 : width;
    var left = alignRight ? anchor.right - menuWidth : anchor.left;
    if (left < _margin) left = _margin;
    if (left + menuWidth > size.width - _margin) {
      left = size.width - menuWidth - _margin;
    }
    var openUp = false;
    var top = anchor.bottom + _margin;
    if (top + height > size.height - _margin) {
      final above = anchor.top - _margin - height;
      if (above >= _margin) {
        top = above;
        openUp = true;
      } else {
        top = size.height - _margin - height;
        if (top < _margin) top = _margin;
      }
    }
    final scale = Tween<double>(
      begin: .96,
      end: 1,
    ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
    final alignment = openUp
        ? (alignRight ? Alignment.bottomRight : Alignment.bottomLeft)
        : (alignRight ? Alignment.topRight : Alignment.topLeft);
    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          child: ScaleTransition(
            scale: scale,
            alignment: alignment,
            child: Material(
              type: MaterialType.transparency,
              child: GlassPanel(
                borderRadius: const BorderRadius.all(Radius.circular(22)),
                sigma: 28,
                child: SizedBox(
                  width: menuWidth,
                  height: height,
                  child: ListView(
                    padding: const EdgeInsets.all(6),
                    itemExtent: itemExtent,
                    children: [
                      for (final (index, entry) in entries.indexed)
                        _GlassMenuItem<T>(
                          entry: entry,
                          animation: animation,
                          index: index,
                          autofocus: autofocusSelected,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GlassMenuItem<T> extends StatelessWidget {
  const _GlassMenuItem({
    required this.entry,
    required this.animation,
    required this.index,
    this.autofocus = false,
  });

  final GlassMenuEntry<T> entry;
  final Animation<double> animation;
  final int index;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final start = (index * .06).clamp(0.0, .48).toDouble();
    final revealed = CurvedAnimation(
      parent: animation,
      curve: Interval(start, 1, curve: Curves.easeOutCubic),
    );
    final labelColor = entry.enabled
        ? (entry.selected ? colors.primary : colors.onSurface)
        : colors.onSurfaceVariant.withValues(alpha: .45);
    return FadeTransition(
      opacity: revealed,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, .3),
          end: Offset.zero,
        ).animate(revealed),
        child: InkWell(
          autofocus: autofocus && entry.selected && entry.enabled,
          onTap: entry.enabled
              ? () {
                  HapticFeedback.selectionClick();
                  Navigator.of(context).pop<T>(entry.value);
                }
              : null,
          borderRadius: BorderRadius.circular(14),
          overlayColor: WidgetStateProperty.resolveWith<Color?>((states) {
            if (states.contains(WidgetState.pressed) ||
                states.contains(WidgetState.hovered)) {
              return colors.primary.withValues(alpha: .12);
            }
            if (states.contains(WidgetState.focused)) {
              return colors.primary.withValues(alpha: .18);
            }
            return Colors.transparent;
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                if (entry.leading != null) ...[
                  IconTheme.merge(
                    data: IconThemeData(
                      size: 20,
                      color: entry.enabled
                          ? colors.onSurfaceVariant
                          : colors.onSurfaceVariant.withValues(alpha: .4),
                    ),
                    child: entry.leading!,
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: DefaultTextStyle.merge(
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: entry.selected
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: labelColor,
                    ),
                    child: entry.label,
                  ),
                ),
                if (entry.trailing != null)
                  IconTheme.merge(
                    data: const IconThemeData(size: 18),
                    child: entry.trailing!,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class GlassBottomNavigation extends StatelessWidget {
  const GlassBottomNavigation({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
  });

  static const height = 64.0;
  static const sideMargin = 12.0;
  static const bottomMargin = 12.0;
  static const contentInset = height + bottomMargin + 8;

  final int? selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavigationDestination> destinations;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final idle = dark
        ? Colors.white.withValues(alpha: .78)
        : Colors.black.withValues(alpha: .62);
    return GlassPanel(
      borderRadius: const BorderRadius.all(Radius.circular(32)),
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            for (final (index, destination) in destinations.indexed)
              Expanded(
                child: Semantics(
                  container: true,
                  button: true,
                  selected: index == selectedIndex,
                  child: Tooltip(
                    message: destination.label,
                    excludeFromSemantics: true,
                    child: PressScale(
                      scale: .9,
                      child: InkWell(
                        key: ValueKey('glass-nav-$index'),
                        overlayColor: WidgetStateProperty.all(
                          Colors.transparent,
                        ),
                        splashFactory: NoSplash.splashFactory,
                        highlightColor: Colors.transparent,
                        onTap: () {
                          HapticFeedback.selectionClick();
                          onDestinationSelected(index);
                        },
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                curve: Curves.easeOutCubic,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: index == selectedIndex
                                      ? colors.primary.withValues(
                                          alpha: dark ? .26 : .16,
                                        )
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(13),
                                ),
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 150),
                                  switchInCurve: Curves.easeOutBack,
                                  switchOutCurve: Curves.easeInCubic,
                                  transitionBuilder: (child, animation) =>
                                      FadeTransition(
                                        opacity: animation,
                                        child: ScaleTransition(
                                          scale: animation,
                                          child: child,
                                        ),
                                      ),
                                  child: IconTheme(
                                    key: ValueKey(
                                      'glass-nav-icon-$index-'
                                      '${index == selectedIndex}',
                                    ),
                                    data: IconThemeData(
                                      size: 21,
                                      color: index == selectedIndex
                                          ? colors.primary
                                          : idle,
                                    ),
                                    child: index == selectedIndex
                                        ? destination.selectedIcon ??
                                              destination.icon
                                        : destination.icon,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 3),
                              AnimatedDefaultTextStyle(
                                duration: const Duration(milliseconds: 160),
                                style: TextStyle(
                                  fontSize: 11,
                                  height: 1.1,
                                  fontWeight: index == selectedIndex
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: index == selectedIndex
                                      ? colors.primary
                                      : idle,
                                ),
                                child: Text(
                                  destination.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class GlassBackToTopButton extends StatelessWidget {
  const GlassBackToTopButton({
    super.key,
    required this.visible,
    this.onPressed,
  });

  static const size = 46.0;

  final bool visible;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      offset: visible ? Offset.zero : const Offset(0, .35),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: IgnorePointer(
          ignoring: !visible,
          child: GlassPanel(
            borderRadius: const BorderRadius.all(Radius.circular(size / 2)),
            child: SizedBox(
              width: size,
              height: size,
              child: IconButton(
                key: const ValueKey('glass-back-to-top'),
                tooltip: '回到顶部',
                onPressed: onPressed,
                icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 28),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
