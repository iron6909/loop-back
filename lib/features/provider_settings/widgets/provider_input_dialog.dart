/// 配置输入对话框：保留可见标签，Enter 提交；Key 始终为空且禁用输入建议。
library;

import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';

class ProviderInputDialog extends StatefulWidget {
  const ProviderInputDialog({
    super.key,
    required this.title,
    required this.initial,
    required this.validate,
    this.secret = false,
    this.hint,
  });
  final String title;
  final String initial;
  final String? Function(String) validate;
  final bool secret;
  final String? hint;
  @override
  State<ProviderInputDialog> createState() => _ProviderInputDialogState();
}

class _ProviderInputDialogState extends State<ProviderInputDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  String? _error;
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    final error = widget.validate(value);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        obscureText: widget.secret,
        autocorrect: false,
        enableSuggestions: false,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: widget.title,
          helperText: widget.hint,
          errorText: _error,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.save)),
      ],
    );
  }
}
