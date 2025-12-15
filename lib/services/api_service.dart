// lib/services/api_service.dart

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/game.dart';
import '../models/analysis_result.dart';

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
  // General requests
  static const Duration _timeoutDefault = Duration(seconds: 60);

  // Analyze can legitimately take longer (Render cold start + Steam paging)
  static const Duration _timeoutAnalyze = Duration(seconds: 240);

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
        .timeout(_timeoutDefault);

    if (response.statusCode != 200) {
      throw Exception('Search failed (${response.statusCode}): ${response.body}');
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
  //    Supports: review_count, filter, language
  // ---------------------------------------------------
  Future<AnalysisResult> analyzeReviews(
    String appId, {
    int reviewCount = 1000,
    String filter = 'recent',   // recent | updated | all
    String language = 'english',
  }) async {
    final uri = Uri.parse('$_baseUrl/analyze');

    final response = await http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'app_id': appId,
            'review_count': reviewCount,
            'filter': filter,
            'language': language,
          }),
        )
        .timeout(_timeoutAnalyze);

    if (response.statusCode != 200) {
      throw Exception('Analyze failed (${response.statusCode}): ${response.body}');
    }

    final Map<String, dynamic> data =
        jsonDecode(response.body) as Map<String, dynamic>;

    return AnalysisResult.fromJson(data);
  }

  // ---------------------------------------------------
  // 3. PAGINATED THEMED REVIEWS  ->  GET /reviews
  //    Must match the same: total_count, filter, language
  // ---------------------------------------------------
  Future<ReviewPageResult> fetchPaginatedReviews(
    String appId, {
    required int offset,
    required int limit,
    required int totalCount,
    String filter = 'recent',
    String language = 'english',
  }) async {
    final uri = Uri.parse('$_baseUrl/reviews').replace(
      queryParameters: {
        'app_id': appId,
        'offset': offset.toString(),
        'limit': limit.toString(),
        'total_count': totalCount.toString(),
        'filter': filter,
        'language': language,
      },
    );

    final response = await http.get(uri).timeout(_timeoutDefault);

    if (response.statusCode != 200) {
      throw Exception('Reviews fetch failed (${response.statusCode}): ${response.body}');
    }

    final Map<String, dynamic> data =
        jsonDecode(response.body) as Map<String, dynamic>;

    return ReviewPageResult.fromJson(data);
  }

  // (Optional but useful) 4. EXPORT CSV -> GET /export
  Future<http.Response> exportCsv(
    String appId, {
    required int totalCount,
    String filter = 'recent',
    String language = 'english',
  }) async {
    final uri = Uri.parse('$_baseUrl/export').replace(
      queryParameters: {
        'app_id': appId,
        'total_count': totalCount.toString(),
        'filter': filter,
        'language': language,
      },
    );

    final response = await http.get(uri).timeout(_timeoutDefault);

    if (response.statusCode != 200) {
      throw Exception('Export failed (${response.statusCode}): ${response.body}');
    }

    return response; // caller can save bytes / trigger download
  }
}
