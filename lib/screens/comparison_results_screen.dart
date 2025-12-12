import 'package:flutter/material.dart';
import '../models/game.dart';
import '../models/analysis_result.dart';
import '../services/api_service.dart';

class ComparisonResultsScreen extends StatefulWidget {
  final Game game1;
  final Game game2;

  const ComparisonResultsScreen({
    super.key,
    required this.game1,
    required this.game2,
  });

  @override
  State<ComparisonResultsScreen> createState() =>
      _ComparisonResultsScreenState();
}

class _ComparisonResultsScreenState extends State<ComparisonResultsScreen> {
  final ApiService _apiService = ApiService();

  AnalysisResult? _result1;
  AnalysisResult? _result2;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchComparisonData();
  }

  // --- Core Logic: Fetch Data for Both Games ---
  Future<void> _fetchComparisonData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Fetch analysis for both games in sequence (you could also use Future.wait)
      final result1 = await _apiService.analyzeReviews(widget.game1.appid);
      final result2 = await _apiService.analyzeReviews(widget.game2.appid);

      if (!mounted) return;
      setState(() {
        _result1 = result1;
        _result2 = result2;
        _isLoading = false;
      });
    } catch (e) {
      // ignore: avoid_print
      print('Error fetching comparison data: $e');
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load comparison data for one or both games.';
        _isLoading = false;
      });
    }
  }

  // --- Helper Widget: Thematic Score Card for Comparison ---
  Widget _buildThematicScoreCard(String theme, ThemeScore? score) {
    final String title = theme.toUpperCase();
    String verdict;
    Color color;

    if (score == null || score.found == 0) {
      verdict = 'N/A';
      color = Colors.grey;
    } else if (score.positivePercent >= 60) {
      verdict = 'POSITIVE';
      color = Colors.green.shade700;
    } else if (score.negativePercent >= 60) {
      verdict = 'NEGATIVE';
      color = Colors.red.shade700;
    } else {
      verdict = 'MIXED';
      color = Colors.orange.shade700;
    }

    return Column(
      children: [
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(
          verdict,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w900,
            color: color,
          ),
          textAlign: TextAlign.center,
        ),
        if (score != null && score.found > 0)
          Text(
            '${score.positivePercent.toStringAsFixed(1)}% | ${score.found} Reviews',
            style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
            textAlign: TextAlign.center,
          ),
      ],
    );
  }

  // --- Helper Widget: Individual Game Column ---
  Widget _buildGameColumn(Game game, AnalysisResult? result) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Game Header
            Card(
              elevation: 4,
              child: Column(
                children: [
                  Image.network(
                    game.headerImageUrl,
                    height: 80,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        const Icon(Icons.gamepad,
                            size: 80, color: Colors.grey),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Text(
                      game.name,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ),
                  Text(
                    'Total Reviews: ${result?.totalReviewsCollected ?? 'N/A'}',
                  ),
                  Text(
                    'Time-centric reviews: ${result?.totalThemedReviews ?? 'N/A'}',
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),

            const SizedBox(height: 16),
            const Text(
              'THEMATIC SCORES',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: Colors.blueGrey),
            ),
            const Divider(),

            // Explicitly show the three themes from ThematicScores
            const SizedBox(height: 8),
            _buildThematicScoreCard(
                'Length', result?.thematicScores.length),
            const SizedBox(height: 12),
            _buildThematicScoreCard(
                'Grind', result?.thematicScores.grind),
            const SizedBox(height: 12),
            _buildThematicScoreCard(
                'Value', result?.thematicScores.value),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Game Comparison'),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
      ),
      body: _isLoading
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Fetching analysis data for both games...'),
                ],
              ),
            )
          : _error != null
              ? Center(child: Text(_error!))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _buildGameColumn(widget.game1, _result1),
                      const SizedBox(
                        width: 1,
                        height: 600,
                        child: VerticalDivider(
                          width: 20,
                          thickness: 1,
                          color: Colors.grey,
                        ),
                      ),
                      _buildGameColumn(widget.game2, _result2),
                    ],
                  ),
                ),
    );
  }
}
