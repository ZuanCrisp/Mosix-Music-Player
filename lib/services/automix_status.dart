import 'package:flutter/foundation.dart';

enum AutoMixStatus { idle, mixing, crossfading }

final autoMixStatus = ValueNotifier<AutoMixStatus>(AutoMixStatus.idle);
