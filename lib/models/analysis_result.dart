// analysis_result.dart
// Model for the /analyze endpoint response.
//
// Requires: playtime_distribution.dart in the same models folder.
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
      positivePercent: (json['positive_percent'] as num?)?.toDouble() ?? 0.0,
      negativePercent: (json['negative_percent'] as num?)?.toDouble() ?? 0.0,
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
      length:
          ThemeScore.fromJson((json['length'] as Map<String, dynamic>?) ?? {}),
      grind:
          ThemeScore.fromJson((json['grind'] as Map<String, dynamic>?) ?? {}),
      value:
          ThemeScore.fromJson((json['value'] as Map<String, dynamic>?) ?? {}),
    );
  }
}

/// Overall response from the /analyze endpoint.
class AnalysisResult {
  final String appId;

  /// Legacy / UI compatibility: frontend historically used this as "scope".
  /// Your backend keeps this set to the *requested* count (e.g., 1000).
  final int reviewCountUsed;

  /// ✅ NEW: the *actual* number of reviews collected/analyzed (e.g., 22).
  final int reviewCountAnalyzed;

  /// Total reviews collected (backend currently returns analysed_count here).
  /// Keeping this for compatibility with your existing UI usage.
  final int totalReviewsCollected;

  final int totalThemedReviews;
  final ThematicScores thematicScores;
  final PlaytimeDistribution playtimeDistribution;

  /// ✅ NEW: Steam's total reviews for this game under the selected filter/language (may be null).
  final int? steamTotalReviews;

  /// ✅ NEW: Whether the backend believes it can fetch more pages (based on cursor + caps).
  final bool canFetchMore;

  AnalysisResult({
    required this.appId,
    required this.reviewCountUsed,
    required this.reviewCountAnalyzed,
    required this.totalReviewsCollected,
    required this.totalThemedReviews,
    required this.thematicScores,
    required this.playtimeDistribution,
    required this.steamTotalReviews,
    required this.canFetchMore,
  });

  factory AnalysisResult.fromJson(Map<String, dynamic> json) {
    final int reviewCountUsed = (json['review_count_used'] as num?)?.toInt() ?? 0;

    // Prefer the explicit new field. Fall back to old fields if needed.
    final int reviewCountAnalyzed =
        (json['review_count_analyzed'] as num?)?.toInt() ??
            (json['total_reviews_collected'] as num?)?.toInt() ??
            reviewCountUsed;

    final int totalReviewsCollected =
        (json['total_reviews_collected'] as num?)?.toInt() ?? 0;

    final int totalThemedReviews =
        (json['total_themed_reviews'] as num?)?.toInt() ?? 0;

    final int? steamTotalReviews = (json['steam_total_reviews'] as num?)?.toInt();

    bool canFetchMore = true;
    final cacheProgress = json['cache_progress'];
    if (cacheProgress is Map<String, dynamic>) {
      final v = cacheProgress['can_fetch_more'];
      if (v is bool) canFetchMore = v;
    }

    return AnalysisResult(
      appId: json['app_id']?.toString() ?? '',
      reviewCountUsed: reviewCountUsed,
      reviewCountAnalyzed: reviewCountAnalyzed,
      totalReviewsCollected: totalReviewsCollected,
      totalThemedReviews: totalThemedReviews,
      thematicScores: ThematicScores.fromJson(
        (json['thematic_scores'] as Map<String, dynamic>?) ?? {},
      ),
      playtimeDistribution: PlaytimeDistribution.fromJson(
        (json['playtime_distribution'] as Map<String, dynamic>?) ?? {},
      ),
      steamTotalReviews: steamTotalReviews,
      canFetchMore: canFetchMore,
    );
  }
}
