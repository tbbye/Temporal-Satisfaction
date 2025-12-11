import 'dart:convert';
import 'package:http/http.dart' as http;
// Correct relative path: looks for 'models' folder in 'lib'
import '../models/game.dart'; 
import '../models/analysis_result.dart';

// CRITICAL: Ensure this is your correct, deployed Render URL!
const String kBaseUrl = "https://temporal-satisfaction.onrender.com"; 

class ApiService {
  // --- 1. SEARCH FUNCTION (/search) ---
  Future<List<Game>> searchGames(String partialName) async {
    if (partialName.isEmpty) return [];

    try {
      final response = await http.post(
        Uri.parse('$kBaseUrl/search'),
        headers: {'Content-Type': 'application/json; charset=UTF-8'},
        body: jsonEncode({'name': partialName}),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final List<dynamic> results = data['results'];
        return results.map((json) => Game.fromJson(json)).toList();
      } else {
        print("Search error: ${response.statusCode}");
        return [];
      }
    } catch (e) {
      print("Network error during search: $e");
      return [];
    }
  }

  // --- 2. ANALYSIS FUNCTION (/analyze) ---
  Future<AnalysisResult> analyzeReviews(String appId) async {
    try {
      final response = await http.post(
        Uri.parse('$kBaseUrl/analyze'),
        headers: {'Content-Type': 'application/json; charset=UTF-8'},
        body: jsonEncode({'app_id': appId}),
      ).timeout(const Duration(seconds: 40)); 

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        return AnalysisResult.fromJson(data);
      } else {
        throw Exception('Analysis failed with status ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Network error during analysis: $e');
    }
  }
}