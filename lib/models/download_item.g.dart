// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'download_item.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

DownloadItem _$DownloadItemFromJson(Map<String, dynamic> json) => DownloadItem(
  id: json['id'] as String,
  track: Track.fromJson(json['track'] as Map<String, dynamic>),
  service: json['service'] as String,
  status:
      $enumDecodeNullable(_$DownloadStatusEnumMap, json['status']) ??
      DownloadStatus.queued,
  progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
  speedMBps: (json['speedMBps'] as num?)?.toDouble() ?? 0.0,
  bytesReceived: (json['bytesReceived'] as num?)?.toInt() ?? 0,
  bytesTotal: (json['bytesTotal'] as num?)?.toInt() ?? 0,
  filePath: json['filePath'] as String?,
  error: json['error'] as String?,
  errorType: $enumDecodeNullable(_$DownloadErrorTypeEnumMap, json['errorType']),
  preparationStage: json['preparationStage'] as String? ?? '',
  createdAt: DateTime.parse(json['createdAt'] as String),
  qualityOverride: json['qualityOverride'] as String?,
  playlistName: json['playlistName'] as String?,
  playlistPosition: (json['playlistPosition'] as num?)?.toInt(),
  fromBatch: json['fromBatch'] as bool? ?? false,
  preserveQualityVariant: json['preserveQualityVariant'] as bool? ?? false,
  networkDownloadFolder: json['networkDownloadFolder'] as String? ?? '',
);

Map<String, dynamic> _$DownloadItemToJson(DownloadItem instance) =>
    <String, dynamic>{
      'id': instance.id,
      'track': instance.track,
      'service': instance.service,
      'status': _$DownloadStatusEnumMap[instance.status]!,
      'progress': instance.progress,
      'speedMBps': instance.speedMBps,
      'bytesReceived': instance.bytesReceived,
      'bytesTotal': instance.bytesTotal,
      'filePath': instance.filePath,
      'error': instance.error,
      'errorType': _$DownloadErrorTypeEnumMap[instance.errorType],
      'preparationStage': instance.preparationStage,
      'createdAt': instance.createdAt.toIso8601String(),
      'qualityOverride': instance.qualityOverride,
      'playlistName': instance.playlistName,
      'playlistPosition': instance.playlistPosition,
      'fromBatch': instance.fromBatch,
      'preserveQualityVariant': instance.preserveQualityVariant,
      'networkDownloadFolder': instance.networkDownloadFolder,
    };

const _$DownloadStatusEnumMap = {
  DownloadStatus.queued: 'queued',
  DownloadStatus.downloading: 'downloading',
  DownloadStatus.finalizing: 'finalizing',
  DownloadStatus.completed: 'completed',
  DownloadStatus.failed: 'failed',
  DownloadStatus.skipped: 'skipped',
};

const _$DownloadErrorTypeEnumMap = {
  DownloadErrorType.unknown: 'unknown',
  DownloadErrorType.notFound: 'notFound',
  DownloadErrorType.rateLimit: 'rateLimit',
  DownloadErrorType.network: 'network',
  DownloadErrorType.permission: 'permission',
  DownloadErrorType.verificationRequired: 'verificationRequired',
};
