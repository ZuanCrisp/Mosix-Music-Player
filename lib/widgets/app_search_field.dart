import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mosix/providers/runtime_profile_provider.dart';
import 'package:mosix/theme/app_tokens.dart';
import 'package:mosix/theme/mosix_theme.dart';
import 'package:mosix/widgets/app_icon.dart';
import 'package:mosix/widgets/app_icon_button.dart';
import 'package:mosix/widgets/mosix_chrome.dart';

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

  /// See [MosixGlass.samplesBackdrop]: false where the field scrolls over
  /// the plain page background.
  final bool samplesBackdrop;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final mosix = context.isMosix;
    final radius = BorderRadius.circular(
      mosix ? 28 : context.tokens.radiusSheet,
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
              AppIcon(mosix ? CupertinoIcons.search : Icons.search),
          suffixIcon:
              suffixIcon ??
              (value.text.isEmpty
                  ? null
                  : AppIconButton(
                      tooltip: clearTooltip,
                      icon: AppIcon(
                        mosix
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
            borderSide: mosix
                ? BorderSide.none
                : BorderSide(color: colorScheme.primary, width: 2),
          ),
          filled: true,
          fillColor: mosix
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
    if (!mosix) return field;
    return Consumer(
      builder: (context, ref, child) => MosixGlass.navigation(
        radius: 28,
        blurEnabled: ref.watch(mosixBlurEnabledProvider),
        samplesBackdrop: samplesBackdrop,
        child: child!,
      ),
      child: field,
    );
  }
}
