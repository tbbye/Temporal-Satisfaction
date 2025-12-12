// lib/models/playtime_distribution.dart

class PlaytimeDistribution {
  final List<double> histogramBuckets;
  final double percentile25th;
  final double medianHours;
  final double percentile75th;
  final String interpretation;

  PlaytimeDistribution({
    required this.histogramBuckets,
    required this.percentile25th,
    required this.medianHours,
    required this.percentile75th,
    required this.interpretation,
  });

  factory PlaytimeDistribution.fromJson(Map<String, dynamic> json) {
    final List<dynamic> bucketsDynamic =
        json['histogram_buckets'] as List<dynamic>? ?? const [];
    final List<double> buckets =
        bucketsDynamic.map((e) => (e as num).toDouble()).toList();

    return PlaytimeDistribution(
      histogramBuckets: buckets,
      percentile25th: (json['percentile_25th'] as num?)?.toDouble() ?? 0.0,
      medianHours: (json['median_hours'] as num?)?.toDouble() ?? 0.0,
      percentile75th: (json['percentile_75th'] as num?)?.toDouble() ?? 0.0,
      interpretation: json['interpretation']?.toString() ?? '',
    );
  }
}
