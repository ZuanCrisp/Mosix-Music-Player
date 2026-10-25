import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/services/custom_font_service.dart';

final customFontFamilyProvider = FutureProvider<String?>((ref) {
  final id = ref.watch(themeProvider.select((theme) => theme.customFontId));
  return CustomFontService.instance.restore(id);
});
