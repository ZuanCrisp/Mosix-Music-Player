import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart'
    show CupertinoButton, CupertinoDynamicColor, kCupertinoModalBarrierColor;
import 'package:mosix/theme/app_tokens.dart';
import 'package:mosix/theme/mornye_theme.dart';
import 'package:mosix/widgets/mornye_chrome.dart';
import 'package:mosix/theme/mornye_icons.dart';

/// The drag handle shown at the top of every modal sheet.
///
/// Sheets using Material's `showDragHandle` should not add this handle.
class AppSheetHandle extends StatelessWidget {
  const AppSheetHandle({super.key, this.margin});

  /// Overrides the default spacing around the handle. Sheets whose first row
  /// already carries top padding pass [EdgeInsets.zero].
  final EdgeInsetsGeometry? margin;

  static const double _width = 40;
  static const double _height = 4;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return ExcludeSemantics(
      child: Center(
        child: Container(
          width: _width,
          height: _height,
          margin:
              margin ??
              EdgeInsets.only(top: tokens.gapMd, bottom: tokens.gapSm),
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(_height / 2),
          ),
        ),
      ),
    );
  }
}

/// Standard chrome for modal sheet content: drag handle, optional title block,
/// height cap, keyboard inset and bottom safe area, so each sheet only supplies
/// its own body.
class AppBottomSheet extends StatelessWidget {
  const AppBottomSheet({
    super.key,
    required this.child,
    this.showHandle = true,
    this.title,
    this.subtitle,
    this.maxHeightFactor,
  });

  final Widget child;
  final bool showHandle;

  /// Leading title row. Rendered with the app's single sheet-title style
  /// instead of the three variants that had accumulated across sheets.
  final String? title;

  /// Secondary line under [title], e.g. the track a sheet is acting on.
  final String? subtitle;

  /// Caps the sheet at this fraction of the screen height.
  final double? maxHeightFactor;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final theme = Theme.of(context);

    Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHandle) const AppSheetHandle(),
        if (title != null)
          Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.gapXl,
              tokens.gapLg,
              tokens.gapXl,
              subtitle == null ? tokens.gapSm : tokens.gapXs,
            ),
            child: Text(
              title!,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        if (subtitle != null)
          Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.gapXl,
              0,
              tokens.gapXl,
              tokens.gapMd,
            ),
            child: Text(
              subtitle!,
              maxLines: context.isMornye ? 3 : 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        Flexible(child: child),
      ],
    );

    if (maxHeightFactor != null) {
      content = ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * maxHeightFactor!,
        ),
        child: content,
      );
    }

    // Sheets containing text fields must lift above the keyboard; doing it here
    // means no call site has to remember `viewInsets`.
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: SafeArea(top: false, child: content),
    );
  }
}

/// Opens a modal bottom sheet wrapped in [AppBottomSheet].
///
/// The shape comes from `ThemeData.bottomSheetTheme`, which is derived from
/// [AppTokens.radiusSheet]; call sites no longer pass a `shape` and therefore
/// cannot drift from the scale.
Future<T?> showAppBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  String? title,
  String? subtitle,
  double? maxHeightFactor,
  bool isScrollControlled = true,
  bool isDismissible = true,
  bool enableDrag = true,
  bool useRootNavigator = false,
  bool showHandle = true,
  Color? backgroundColor,
}) {
  return showAppModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    useRootNavigator: useRootNavigator,
    backgroundColor: backgroundColor,
    builder: (sheetContext) => AppBottomSheet(
      showHandle: showHandle,
      title: title,
      subtitle: subtitle,
      maxHeightFactor: maxHeightFactor,
      child: builder(sheetContext),
    ),
  );
}

/// Adaptive surface for sheets which already supply their own header/layout.
Future<T?> showAppModalBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool useRootNavigator = false,
  bool useSafeArea = false,
  BoxConstraints? constraints,
  Color? backgroundColor,
}) {
  final mornye = context.isMornye;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    useRootNavigator: useRootNavigator,
    useSafeArea: useSafeArea,
    constraints: constraints,
    backgroundColor: mornye ? Colors.transparent : backgroundColor,
    barrierColor: mornye
        ? CupertinoDynamicColor.resolve(kCupertinoModalBarrierColor, context)
        : null,
    elevation: mornye ? 0 : null,
    builder: (context) => mornye
        ? MornyeGlassPanel.overlay(child: Builder(builder: builder))
        : builder(context),
  );
}

/// Flat rows sit directly on a sheet's glass; Material keeps its ListTile.
class AppSheetOption extends StatelessWidget {
  const AppSheetOption({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.contentPadding,
    this.enabled = true,
  });

  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? contentPadding;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!context.isMornye) {
      return ListTile(
        title: title,
        subtitle: subtitle,
        leading: leading,
        trailing: trailing,
        onTap: onTap,
        contentPadding: contentPadding,
        enabled: enabled,
      );
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget adaptedIcon(Widget widget, double size) {
      if (widget case Icon(:final icon?)) {
        return Icon(
          mornyeIconFor(icon),
          size: size,
          color: enabled ? widget.color ?? scheme.primary : theme.disabledColor,
        );
      }
      return widget;
    }

    return CupertinoButton(
      onPressed: enabled ? onTap : null,
      padding:
          contentPadding ??
          const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      child: Row(
        children: [
          if (leading != null) ...[
            adaptedIcon(leading!, 24),
            const SizedBox(width: 16),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DefaultTextStyle(
                  style: theme.textTheme.bodyLarge!.copyWith(
                    color: enabled ? scheme.onSurface : theme.disabledColor,
                    fontWeight: FontWeight.w500,
                  ),
                  child: title,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  DefaultTextStyle(
                    style: theme.textTheme.bodySmall!.copyWith(
                      color: enabled
                          ? scheme.onSurfaceVariant
                          : theme.disabledColor,
                    ),
                    child: subtitle!,
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            adaptedIcon(trailing!, 20),
          ],
        ],
      ),
    );
  }
}
