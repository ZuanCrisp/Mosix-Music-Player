import 'dart:io';

import 'package:crypto/crypto.dart';

/// A rejected certificate, offered for explicit, per-connection trust in the UI.
class NetworkCertificateException implements Exception {
  const NetworkCertificateException({
    required this.origin,
    required this.fingerprint,
  });

  factory NetworkCertificateException.fromCertificate(
    Uri server,
    X509Certificate certificate,
  ) => NetworkCertificateException(
    origin: server.origin,
    fingerprint: sha256.convert(certificate.der).toString(),
  );

  final String origin;
  final String fingerprint;

  @override
  String toString() => 'The server certificate is not trusted';
}
