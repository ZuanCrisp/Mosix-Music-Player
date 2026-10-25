import 'package:mornye/models/download_item.dart';

/// Null permits legacy message inference; unknown preserves a typed failure's
/// original message without mistaking provider authentication for a challenge.
DownloadErrorType? downloadErrorTypeFromBackend(String? errorType) {
  switch (errorType?.trim().toLowerCase()) {
    case 'not_found':
      return DownloadErrorType.notFound;
    case 'rate_limit':
      return DownloadErrorType.rateLimit;
    case 'network':
      return DownloadErrorType.network;
    case 'permission':
      return DownloadErrorType.permission;
    case 'verification_required':
      return DownloadErrorType.verificationRequired;
    case 'authentication_error':
    case 'provider_auth_failed':
    case 'request_auth_invalid':
    case 'provider_reauth_required':
      return DownloadErrorType.unknown;
    default:
      return null;
  }
}
