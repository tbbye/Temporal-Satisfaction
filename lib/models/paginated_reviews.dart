// lib/models/paginated_reviews.dart

/// Simple container for a page of themed reviews from the backend.
class PaginatedReviews {
  /// List of review objects (we keep them as dynamic for now,
  /// since the UI treats them dynamically too).
  final List<dynamic> reviews;

  /// Total number of themed reviews available for this query/scope.
  final int totalAvailable;

  PaginatedReviews({
    required this.reviews,
    required this.totalAvailable,
  });

  factory PaginatedReviews.fromJson(Map<String, dynamic> json) {
    return PaginatedReviews(
      // The backend should return a list of review objects under 'reviews'
      reviews: (json['reviews'] as List<dynamic>? ?? []),
      // Adjust this key if your backend uses a different name like 'total' etc.
      totalAvailable: (json['total_available'] ?? json['total'] ?? 0) as int,
    );
  }
}
