class AnalysisResult {
  final int totalReviewsCollected;
  final int timeCentricReviewsFound;
  final double positiveSentimentPercent;
  final double negativeSentimentPercent;

  AnalysisResult({
    required this.totalReviewsCollected,
    required this.timeCentricReviewsFound,
    required this.positiveSentimentPercent,
    required this.negativeSentimentPercent,
  });

  factory AnalysisResult.fromJson(Map<String, dynamic> json) {
    return AnalysisResult(
      totalReviewsCollected: json['total_reviews_collected'] as int,
      timeCentricReviewsFound: json['time_centric_reviews_found'] as int,
      positiveSentimentPercent: json['positive_sentiment_percent'] as double,
      negativeSentimentPercent: json['negative_sentiment_percent'] as double,
    );
  }
}