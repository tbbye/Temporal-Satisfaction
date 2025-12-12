// analysis_result.dart (MODEL FILE - assuming this is the file name for your models)

// Note: You must ensure playtime_distribution.dart exists in the models folder
import 'playtime_distribution.dart';

/// Score for a single theme.
class ThemeScore {
  final int found;
  final double positivePercent;
  final double negativePercent;

  const ThemeScore({
    required this.found,
    required this.positivePercent,
    required this.negativePercent,
  });

  factory ThemeScore.fromJson(Map<String, dynamic> json) {
    return ThemeScore(
      found: (json['found'] as num?)?.toInt() ?? 0,
      positivePercent:
          (json['positive_percent'] as num?)?.toDouble() ?? 0.0,
      negativePercent:
          (json['negative_percent'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

/// Container for the three theme scores (length, grind, value).
class ThematicScores {
  final ThemeScore length;
  final ThemeScore grind;
  final ThemeScore value;

  const ThematicScores({
    required this.length,
    required this.grind,
    required this.value,
  });

  factory ThematicScores.fromJson(Map<String, dynamic> json) {
    return ThematicScores(
      length: ThemeScore.fromJson(
          (json['length'] as Map<String, dynamic>? ?? const {})),
      grind: ThemeScore.fromJson(
          (json['grind'] as Map<String, dynamic>? ?? const {})),
      value: ThemeScore.fromJson(
          (json['value'] as Map<String, dynamic>? ?? const {})),
    );
  }
}

/// Overall response from the /analyze endpoint.
class AnalysisResult {
  final String appId;
  final int reviewCountUsed; // IMPORTANT: Added to track the count used for caching
  final int totalReviewsCollected;
  final int totalThemedReviews;
  final ThematicScores thematicScores;
  final PlaytimeDistribution playtimeDistribution;

  AnalysisResult({
    required this.appId,
    required this.reviewCountUsed,
    required this.totalReviewsCollected,
    required this.totalThemedReviews,
    required this.thematicScores,
    required this.playtimeDistribution,
  });

  factory AnalysisResult.fromJson(Map<String, dynamic> json) {
    return AnalysisResult(
      appId: json['app_id']?.toString() ?? '',
      reviewCountUsed: (json['review_count_used'] as num?)?.toInt() ?? 0,
      totalReviewsCollected:
          (json['total_reviews_collected'] as num?)?.toInt() ?? 0,
      totalThemedReviews:
          (json['total_themed_reviews'] as num?)?.toInt() ?? 0,
      thematicScores: ThematicScores.fromJson(
        (json['thematic_scores'] as Map<String, dynamic>? ?? const {}),
      ),
      playtimeDistribution: PlaytimeDistribution.fromJson(
        (json['playtime_distribution'] as Map<String, dynamic>? ?? const {}),
      ),
    );
  }
}