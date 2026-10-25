class RetailBarcodeData {
  final String value;
  final String symbology;
  final String modules;
  final int quietZoneModules;

  const RetailBarcodeData({
    required this.value,
    required this.symbology,
    required this.modules,
    required this.quietZoneModules,
  });
}

const _eanLeftOdd = <String>[
  '0001101',
  '0011001',
  '0010011',
  '0111101',
  '0100011',
  '0110001',
  '0101111',
  '0111011',
  '0110111',
  '0001011',
];

const _eanLeftEven = <String>[
  '0100111',
  '0110011',
  '0011011',
  '0100001',
  '0011101',
  '0111001',
  '0000101',
  '0010001',
  '0001001',
  '0010111',
];

const _eanRight = <String>[
  '1110010',
  '1100110',
  '1101100',
  '1000010',
  '1011100',
  '1001110',
  '1010000',
  '1000100',
  '1001000',
  '1110100',
];

const _ean13Parity = <String>[
  'LLLLLL',
  'LLGLGG',
  'LLGGLG',
  'LLGGGL',
  'LGLLGG',
  'LGGLLG',
  'LGGGLL',
  'LGLGLG',
  'LGLGGL',
  'LGGLGL',
];

// Code 128 module widths, including start/check/stop symbols. It is used only
// as an exact-value fallback when a numeric identifier is not a valid UPC-A or
// EAN-13. Valid retail identifiers always use their native symbology.
const _code128Patterns = <String>[
  '212222',
  '222122',
  '222221',
  '121223',
  '121322',
  '131222',
  '122213',
  '122312',
  '132212',
  '221213',
  '221312',
  '231212',
  '112232',
  '122132',
  '122231',
  '113222',
  '123122',
  '123221',
  '223211',
  '221132',
  '221231',
  '213212',
  '223112',
  '312131',
  '311222',
  '321122',
  '321221',
  '312212',
  '322112',
  '322211',
  '212123',
  '212321',
  '232121',
  '111323',
  '131123',
  '131321',
  '112313',
  '132113',
  '132311',
  '211313',
  '231113',
  '231311',
  '112133',
  '112331',
  '132131',
  '113123',
  '113321',
  '133121',
  '313121',
  '211331',
  '231131',
  '213113',
  '213311',
  '213131',
  '311123',
  '311321',
  '331121',
  '312113',
  '312311',
  '332111',
  '314111',
  '221411',
  '431111',
  '111224',
  '111422',
  '121124',
  '121421',
  '141122',
  '141221',
  '112214',
  '112412',
  '122114',
  '122411',
  '142112',
  '142211',
  '241211',
  '221114',
  '413111',
  '241112',
  '134111',
  '111242',
  '121142',
  '121241',
  '114212',
  '124112',
  '124211',
  '411212',
  '421112',
  '421211',
  '212141',
  '214121',
  '412121',
  '111143',
  '111341',
  '131141',
  '114113',
  '114311',
  '411113',
  '411311',
  '113141',
  '114131',
  '311141',
  '411131',
  '211412',
  '211214',
  '211232',
  '2331112',
];

RetailBarcodeData? encodeRetailBarcode(String rawValue) {
  final value = rawValue.replaceAll(RegExp(r'[\s-]+'), '');
  if (value.isEmpty || !RegExp(r'^\d+$').hasMatch(value)) return null;

  if (value.length == 12 && hasValidGtinCheckDigit(value)) {
    return RetailBarcodeData(
      value: value,
      symbology: 'UPC-A',
      modules: _encodeEan13('0$value'),
      quietZoneModules: 11,
    );
  }
  if (value.length == 13 && hasValidGtinCheckDigit(value)) {
    return RetailBarcodeData(
      value: value,
      symbology: 'EAN-13',
      modules: _encodeEan13(value),
      quietZoneModules: 11,
    );
  }

  return RetailBarcodeData(
    value: value,
    symbology: 'CODE 128',
    modules: _encodeCode128B(value),
    quietZoneModules: 10,
  );
}

bool hasValidGtinCheckDigit(String value) {
  if (value.length < 2 || !RegExp(r'^\d+$').hasMatch(value)) return false;
  var sum = 0;
  var useThree = true;
  for (var i = value.length - 2; i >= 0; i--) {
    final digit = value.codeUnitAt(i) - 48;
    sum += digit * (useThree ? 3 : 1);
    useThree = !useThree;
  }
  final expected = (10 - (sum % 10)) % 10;
  return expected == value.codeUnitAt(value.length - 1) - 48;
}

String _encodeEan13(String value) {
  final first = value.codeUnitAt(0) - 48;
  final parity = _ean13Parity[first];
  final out = StringBuffer('101');
  for (var i = 1; i <= 6; i++) {
    final digit = value.codeUnitAt(i) - 48;
    out.write(parity[i - 1] == 'L' ? _eanLeftOdd[digit] : _eanLeftEven[digit]);
  }
  out.write('01010');
  for (var i = 7; i <= 12; i++) {
    out.write(_eanRight[value.codeUnitAt(i) - 48]);
  }
  out.write('101');
  return out.toString();
}

String _encodeCode128B(String value) {
  const startB = 104;
  final codes = <int>[startB];
  var checksum = startB;
  for (var i = 0; i < value.length; i++) {
    final code = value.codeUnitAt(i) - 32;
    codes.add(code);
    checksum += code * (i + 1);
  }
  codes
    ..add(checksum % 103)
    ..add(106);

  final out = StringBuffer();
  for (final code in codes) {
    final widths = _code128Patterns[code];
    for (var i = 0; i < widths.length; i++) {
      final width = widths.codeUnitAt(i) - 48;
      out.write(List.filled(width, i.isEven ? '1' : '0').join());
    }
  }
  return out.toString();
}
