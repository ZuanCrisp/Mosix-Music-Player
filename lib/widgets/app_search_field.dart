import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/mornye_chrome.dart';

/// The standard search field used by top-level app surfaces.
///
/// Keeping the decoration here prevents Settings, Store, and future search
/// surfaces from drifting into slightly different shapes and colors.
class AppSearchField extends StatelessWidget {
  const AppSearchField({
    super.key,
    required this.controller,
    required this.hintText,
    required this.clearTooltip,
    this.onChanged,
    required this.onClear,
    this.onSubmitted,
    this.prefixIcon,
    this.suffixIcon,
    this.focusNode,
    this.autofocus = false,
    this.samplesBackdrop = true,
  });

  final TextEditingController controller;
  final String hintText;
  final String clearTooltip;
  final ValueChanged<String>? onChanged;
  final VoidCallback onClear;
  final ValueChanged<String>? onSubmitted;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final FocusNode? focusNode;
  final bool autofocus;

  /// See [MornyeGlass.samplesBackdrop]: false where the field scrolls over
  /// the plain page background.
  final bool samplesBackdrop;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final mornye = context.isMornye;
    final radius = BorderRadius.circular(
      mornye ? 28 : context.tokens.radiusSheet,
    );

    final field = ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) => TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: hintText,
          prefixIcon:
              prefixIcon ??
              AppIcon(mornye ? CupertinoIcons.search : Icons.search),
          suffixIcon:
              suffixIcon ??
              (value.text.isEmpty
                  ? null
                  : AppIconButton(
                      tooltip: clearTooltip,
                      icon: AppIcon(
                        mornye
                            ? CupertinoIcons.clear_circled_solid
                            : Icons.clear,
                      ),
                      onPressed: () {
                        controller.clear();
                        onClear();
                      },
                    )),
          // Expressive search bar: an outline-free tonal pill. Focus keeps a
          // visible 2dp ring.
          border: OutlineInputBorder(
            borderRadius: radius,
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: radius,
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: radius,
            borderSide: mornye
                ? BorderSide.none
                : BorderSide(color: colorScheme.primary, width: 2),
          ),
          filled: true,
          fillColor: mornye
              ? Colors.transparent
              : colorScheme.surfaceContainerHigh,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 16,
          ),
        ),
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        onTapOutside: (_) => FocusScope.of(context).unfocus(),
      ),
    );
    if (!mornye) return field;
    return Consumer(
      builder: (context, ref, child) => MornyeGlass.navigation(
        radius: 28,
        blurEnabled: ref.watch(mornyeBlurEnabledProvider),
        samplesBackdrop: samplesBackdrop,
        child: child!,
      ),
      child: field,
    );
  }
}
