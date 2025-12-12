// lib/models/review.dart

class Review {
  final String sentimentLabel;
  final double playtimeHours;
  final List<String> themeTags;
  final String reviewText;

  const Review({
    required this.sentimentLabel,
    required this.playtimeHours,
    required this.themeTags,
    required this.reviewText,
  });

  static double _safeParsePlaytime(dynamic value) {
    if (value == null) return 0.0;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  factory Review.fromJson(Map<String, dynamic> json) {
    return Review(
      sentimentLabel: json['sentiment_label'] as String? ?? 'Neutral',
      playtimeHours: _safeParsePlaytime(json['playtime_hours']),
      themeTags: (json['theme_tags'] as List?)
              ?.map((tag) => tag.toString())
              .toList() ??
          <String>[],
      reviewText: json['review_text'] as String? ?? 'No text provided',
    );
  }
}
