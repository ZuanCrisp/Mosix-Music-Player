import 'package:flutter/material.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/l10n/l10n.dart';

/// Shared discard-unsaved-changes confirmation dialog used by priority /
/// selection settings pages.
Future<bool> showDiscardChangesDialog(
  BuildContext context, {
  String? content,
}) async {
  final result = await showAppDialog<bool>(
    context: context,
    builder: (context) => AppAlertDialog(
      title: Text(context.l10n.dialogDiscardChanges),
      content: Text(content ?? context.l10n.dialogUnsavedChanges),
      actions: [
        AppDialogAction(
          isDefault: true,
          onPressed: () => Navigator.pop(context, false),
          child: Text(context.l10n.dialogCancel),
        ),
        AppDialogAction(
          filled: true,
          isDestructive: true,
          onPressed: () => Navigator.pop(context, true),
          child: Text(context.l10n.dialogDiscard),
        ),
      ],
    ),
  );
  return result ?? false;
}
