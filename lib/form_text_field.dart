import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_layout.dart';
import 'native_text_input.dart';

class FormTextField extends StatelessWidget {
  const FormTextField({
    super.key,
    required this.controller,
    required this.decoration,
    this.obscure = false,
    this.url = false,
    this.enabled = true,
    this.autofocus = false,
    this.maxLength,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final InputDecoration decoration;
  final bool obscure;
  final bool url;
  final bool enabled;
  final bool autofocus;
  final int? maxLength;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) =>
      AppLayout.isTelevision(context) &&
          defaultTargetPlatform == TargetPlatform.android
      ? _TelevisionTextField(field: this)
      : TextField(
          controller: controller,
          enabled: enabled,
          autofocus: autofocus,
          obscureText: obscure,
          keyboardType: url ? TextInputType.url : null,
          enableSuggestions: !obscure && !url,
          autocorrect: !obscure && !url,
          inputFormatters: [
            if (maxLength != null) LengthLimitingTextInputFormatter(maxLength),
          ],
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          decoration: decoration,
        );
}

class _TelevisionTextField extends StatefulWidget {
  const _TelevisionTextField({required this.field});

  final FormTextField field;

  @override
  State<_TelevisionTextField> createState() => _TelevisionTextFieldState();
}

class _TelevisionTextFieldState extends State<_TelevisionTextField> {
  final _focus = FocusNode();
  var _editing = false;

  FormTextField get _field => widget.field;

  @override
  void didUpdateWidget(_TelevisionTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_editing && !_field.enabled) NativeTextInput.stop();
  }

  @override
  void dispose() {
    if (_editing) NativeTextInput.stop();
    _focus.dispose();
    super.dispose();
  }

  void _edit() {
    setState(() => _editing = true);
    NativeTextInput.start(
      _field.controller.text,
      search: false,
      password: _field.obscure,
      url: _field.url,
      maxLength: _field.maxLength,
      onChanged: (text) {
        if (!mounted) return;
        _field.controller.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
        _field.onChanged?.call(text);
      },
      onDone: (text, submit) {
        if (!mounted) return;
        setState(() => _editing = false);
        _field.controller.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
        _field.onChanged?.call(text);
        if (submit) _field.onSubmitted?.call(text);
      },
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_field.controller, _focus]),
    builder: (context, _) {
      final text = _field.controller.text;
      return InkWell(
        focusNode: _focus,
        autofocus: _field.autofocus,
        canRequestFocus: _field.enabled,
        focusColor: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        onTap: _field.enabled ? _edit : null,
        child: InputDecorator(
          decoration: _field.decoration.copyWith(enabled: _field.enabled),
          isFocused: _focus.hasFocus,
          isEmpty: text.isEmpty,
          child: Text(
            _field.obscure ? '•' * text.length : text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      );
    },
  );
}
