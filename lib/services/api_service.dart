// lib/services/api_service.dart

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/game.dart';
import '../models/analysis_result.dart';

// If you’re on an Android emulator, you may need 10.0.2.2 instead of 127.0.0.1.
// For a real device on the same Wi-Fi, keep your PC’s LAN IP / Flask host here.
const String _baseUrl = 'https://temporal-satisfaction.onrender.com';

class ReviewPageResult {
  final List<dynamic> reviews; // raw JSON maps – converted in the UI
  final int totalAvailable;

  ReviewPageResult({
    required this.reviews,
    required this.totalAvailable,
  });

  factory ReviewPageResult.fromJson(Map<String, dynamic> json) {
    return ReviewPageResult(
      reviews: (json['reviews'] as List? ?? []),
      totalAvailable: json['total_available'] as int? ?? 0,
    );
  }
}

class ApiService {
  static const Duration _timeout = Duration(seconds: 60);

  // ---------------------------------------------------
  // 1. GAME SEARCH  ->  POST /search  { "name": query }
  // ---------------------------------------------------
  Future<List<Game>> searchGames(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    final uri = Uri.parse('$_baseUrl/search');

    final response = await http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'name': trimmed}),
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception(
        'Search failed (${response.statusCode}): ${response.body}',
      );
    }

    final Map<String, dynamic> data =
        jsonDecode(response.body) as Map<String, dynamic>;

    final List<dynamic> rawResults = data['results'] as List? ?? [];

    return rawResults
        .map((item) => Game.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  // ---------------------------------------------------
  // 2. ANALYSE REVIEWS  ->  POST /analyze
  // ---------------------------------------------------
  Future<AnalysisResult> analyzeReviews(
    String appId, {
    int reviewCount = 1000,
  }) async {
    final uri = Uri.parse('$_baseUrl/analyze');

    final response = await http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'app_id': appId,
            'review_count': reviewCount,
          }),
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception(
        'Analyze failed (${response.statusCode}): ${response.body}',
      );
    }

    final Map<String, dynamic> data =
        jsonDecode(response.body) as Map<String, dynamic>;

    return AnalysisResult.fromJson(data);
  }

  // ---------------------------------------------------
  // 3. PAGINATED THEMED REVIEWS  ->  GET /reviews
  // ---------------------------------------------------
  Future<ReviewPageResult> fetchPaginatedReviews(
    String appId, {
    required int offset,
    required int limit,
    required int totalCount,
  }) async {
    final uri = Uri.parse(
      '$_baseUrl/reviews'
      '?app_id=$appId'
      '&offset=$offset'
      '&limit=$limit'
      '&total_count=$totalCount',
    );

    final response = await http.get(uri).timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception(
        'Reviews fetch failed (${response.statusCode}): ${response.body}',
      );
    }

    final Map<String, dynamic> data =
        jsonDecode(response.body) as Map<String, dynamic>;

    return ReviewPageResult.fromJson(data);
  }
}
