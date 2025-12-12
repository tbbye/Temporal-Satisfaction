// lib/screens/analysis_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/gestures.dart';
import 'package:file_saver/file_saver.dart';

import '../models/game.dart';
import '../models/analysis_result.dart';
import '../models/playtime_distribution.dart';
import '../models/review.dart';
import '../services/api_service.dart';

// Your real Buy Me a Coffee URL
const String _buyMeACoffeeUrl = 'https://www.buymeacoffee.com/tbbye';

// Simple helper to open links in the browser
Future<void> _launchExternalUrl(String url) async {
  final Uri uri = Uri.parse(url);
  if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
    // ignore: avoid_print
    print('Could not launch $url');
  }
}

class AnalysisScreen extends StatefulWidget {
  final Game selectedGame;

  // Base URL of your backend
  final String baseUrl = "http://127.0.0.1:5000";

  const AnalysisScreen({
    super.key,
    required this.selectedGame,
  });

  @override
  State<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends State<AnalysisScreen> {
  final ApiService _apiService = ApiService();
  final ScrollController _scrollController = ScrollController();

  AnalysisResult? _analysisResult;
  bool _isLoadingAnalysis = true;
  String? _error;

  // --- Filter State ---
  String? _selectedThemeFilter; // 'length', 'grind', 'value'
  String? _selectedSentimentFilter; // 'Positive', 'Negative', 'Neutral'

  // --- Pagination State ---
  List<Review> _reviews = [];
  int _currentReviewCount = 1000;
  int _currentPageOffset = 0;
  int _totalThemedReviewsAvailable = 0;
  bool _isLoadingReviews = false;
  bool _hasMoreReviews = true;

  @override
  void initState() {
    super.initState();
    // First analysis for this game – no rollback behaviour.
    _fetchAnalysisData(reviewCount: _currentReviewCount, allowRollback: false);
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels ==
            _scrollController.position.maxScrollExtent &&
        !_isLoadingReviews &&
        _hasMoreReviews) {
      _fetchPaginatedReviews(isInitialFetch: false);
    }
  }

  // --- Core Logic: API Data Fetching (Analysis Scores) ---
  // `allowRollback` is only true when you press "Add 1000 more".
  // For the *first* analysis of a game we keep it false – no rollback.
  Future<void> _fetchAnalysisData({
    required int reviewCount,
    bool allowRollback = false,
  }) async {
    // Snapshot of current state in case we *do* want to roll back
    final previousAnalysis = _analysisResult;
    final previousReviewCount = _currentReviewCount;
    final previousReviews = List<Review>.from(_reviews);
    final previousTotalThemedReviews = _totalThemedReviewsAvailable;
    final previousOffset = _currentPageOffset;
    final previousHasMore = _hasMoreReviews;
    final previousThemeFilter = _selectedThemeFilter;
    final previousSentimentFilter = _selectedSentimentFilter;
    final previousError = _error;

    setState(() {
      _isLoadingAnalysis = true;
      _error = null;
    });

    try {
      final result = await _apiService.analyzeReviews(
        widget.selectedGame.appid,
        reviewCount: reviewCount,
      );

      // IMPORTANT: trust what the backend actually used
      // (e.g. 22 reviews if that’s all Steam has)
      setState(() {
        _analysisResult = result;
        _currentReviewCount = result.reviewCountUsed;

        _reviews = [];
        _currentPageOffset = 0;
        _totalThemedReviewsAvailable = result.totalThemedReviews;
        _hasMoreReviews = true;

        _selectedThemeFilter = null;
        _selectedSentimentFilter = null;
        _error = null;
      });

      await _fetchPaginatedReviews(isInitialFetch: true);

      if (!mounted) return;
      setState(() {
        _isLoadingAnalysis = false;
      });
    } catch (e) {
      // ignore: avoid_print
      print('Error fetching analysis data: $e');

      if (!mounted) return;

      setState(() {
        if (allowRollback && previousAnalysis != null) {
          // This was an *expand* attempt and we had older data – roll back.
          _analysisResult = previousAnalysis;
          _currentReviewCount = previousReviewCount;
          _reviews = previousReviews;
          _totalThemedReviewsAvailable = previousTotalThemedReviews;
          _currentPageOffset = previousOffset;
          _hasMoreReviews = previousHasMore;
          _selectedThemeFilter = previousThemeFilter;
          _selectedSentimentFilter = previousSentimentFilter;
          _error = previousError ??
              'Failed to expand the analysis. Showing the last successful results instead.';
        } else {
          // First attempt for this game – nothing to roll back to.
          _error = 'Failed to load analysis for this game.\n$e';
          _analysisResult = null;
          _reviews = [];
          _totalThemedReviewsAvailable = 0;
          _currentPageOffset = 0;
          _hasMoreReviews = false;
        }

        _isLoadingAnalysis = false;
      });
    }
  }

  // --- Core Logic: Paginated Review Fetching ---
  Future<void> _fetchPaginatedReviews({required bool isInitialFetch}) async {
    if (_isLoadingReviews || !_hasMoreReviews) return;

    setState(() {
      _isLoadingReviews = true;
    });

    try {
      final result = await _apiService.fetchPaginatedReviews(
        widget.selectedGame.appid,
        offset: _currentPageOffset,
        limit: 20,
        totalCount: _currentReviewCount,
      );

      final List<Review> newReviews = (result.reviews)
          .map((json) => Review.fromJson(json as Map<String, dynamic>))
          .toList();

      if (!mounted) return;

      setState(() {
        _reviews.addAll(newReviews);
        _totalThemedReviewsAvailable = result.totalAvailable;
        _currentPageOffset += newReviews.length;
        _hasMoreReviews = _currentPageOffset < _totalThemedReviewsAvailable;
        _isLoadingReviews = false;
      });
    } catch (e) {
      // ignore: avoid_print
      print('Error fetching paginated reviews: $e');
      if (!mounted) return;
      setState(() {
        _isLoadingReviews = false;
        _hasMoreReviews = false;
      });
    }
  }

  // --- Filtered Reviews Getter ---
  List<Review> get _filteredReviews {
    List<Review> reviews = List.from(_reviews);

    if (_selectedThemeFilter != null) {
      reviews = reviews.where((review) {
        return review.themeTags.contains(_selectedThemeFilter!.toLowerCase());
      }).toList();
    }

    if (_selectedSentimentFilter != null) {
      reviews = reviews.where((review) {
        return review.sentimentLabel.toLowerCase() ==
            _selectedSentimentFilter!.toLowerCase();
      }).toList();
    }

    return reviews;
  }

  // --- Filter Setter Methods ---
  void _setThemeFilter(String theme) {
    setState(() {
      _selectedThemeFilter =
          (_selectedThemeFilter == theme) ? null : theme; // toggle
    });
  }

  void _setSentimentFilter(String? sentiment) {
    setState(() {
      _selectedSentimentFilter = sentiment;
    });
  }

  // --- Export CSV Logic ---
  Future<void> _exportCSVData() async {
    if (_analysisResult == null) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Preparing data for export... Please wait.'),
      ),
    );

    final url = Uri.parse(
      '${widget.baseUrl}/export?app_id=${widget.selectedGame.appid}&total_count=${_analysisResult!.reviewCountUsed}',
    );

    try {
      final response = await http.get(url);

      if (response.statusCode == 200) {
        final bytes = response.bodyBytes;
        final fileName =
            'analysis_export_${widget.selectedGame.appid}_${DateTime.now().millisecondsSinceEpoch}.csv';

        await FileSaver.instance.saveFile(
          name: fileName,
          bytes: bytes,
          ext: 'csv',
          mimeType: MimeType.csv,
        );

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Successfully exported all themed reviews to $fileName',
            ),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text('Export failed! Status Code: ${response.statusCode}'),
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('An error occurred during export: $e'),
        ),
      );
    }
  }

  // --- UI Helper: Get color based on sentiment ---
  Color _getSentimentColor(String sentiment) {
    switch (sentiment.toLowerCase()) {
      case 'positive':
        return Colors.green.shade600;
      case 'negative':
        return Colors.red.shade600;
      case 'neutral':
        return Colors.blueGrey.shade400;
      default:
        return Colors.grey;
    }
  }

  // --- Playtime Distribution Chart ---
  Widget _buildPlaytimeChart(PlaytimeDistribution distribution) {
    final List<double> buckets = distribution.histogramBuckets;
    final double maxBucketValue =
        buckets.isEmpty ? 0 : buckets.reduce((a, b) => a > b ? a : b);

    final List<String> labels = ['<1h', '1-5h', '5-20h', '20-50h', '50+h'];

    return Padding(
      padding: const EdgeInsets.only(top: 10.0, bottom: 20.0),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: buckets.asMap().entries.map((entry) {
              final int index = entry.key;
              final double value = entry.value;
              final double height =
                  maxBucketValue > 0 ? (value / maxBucketValue) * 100.0 : 0.0;

              return Column(
                children: [
                  Text(
                    '${value.toInt()}',
                    style: const TextStyle(fontSize: 10),
                  ),
                  Container(
                    width: 20,
                    height: height.clamp(0, 100),
                    color: Colors.lightBlue.shade300,
                  ),
                  Text(
                    labels[index],
                    style: const TextStyle(fontSize: 10),
                  ),
                ],
              );
            }).toList(),
          ),
          const SizedBox(height: 15),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              Text(
                '25th: ${distribution.percentile25th.toStringAsFixed(1)}h',
                style: const TextStyle(fontSize: 12),
              ),
              Text(
                'Median: ${distribution.medianHours.toStringAsFixed(1)}h',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(
                '75th: ${distribution.percentile75th.toStringAsFixed(1)}h',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Text(
              'Interpretation: ${distribution.interpretation}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontStyle: FontStyle.italic,
                fontSize: 13,
                color: Colors.blueGrey,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- Thematic Score Card ---
  Widget _buildThematicScoreCard(String theme, ThemeScore score) {
    final isSelected = _selectedThemeFilter == theme;

    String title = theme.toUpperCase();
    String verdict;
    Color color;

    final int found = score.found;
    final double positive = score.positivePercent;
    final double negative = score.negativePercent;

    if (found == 0) {
      verdict = 'N/A';
      color = Colors.grey;
    } else if (positive >= 60) {
      verdict = 'POSITIVE';
      color = Colors.green;
    } else if (negative >= 60) {
      verdict = 'NEGATIVE';
      color = Colors.red;
    } else {
      verdict = 'MIXED';
      color = Colors.orange;
    }

    return GestureDetector(
      onTap: () => _setThemeFilter(theme),
      child: Card(
        color: isSelected ? Colors.lightBlue.shade100 : Colors.white,
        elevation: isSelected ? 5 : 3,
        margin: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            children: [
              Text(
                '$title SENTIMENT',
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 8),
              Text(
                verdict,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: color,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${positive.toStringAsFixed(1)}% Positive | $found Reviews',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              if (isSelected)
                const Padding(
                  padding: EdgeInsets.only(top: 4.0),
                  child: Text(
                    'FILTER ACTIVE',
                    style: TextStyle(fontSize: 10, color: Colors.blue),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Review Sentiment Filter Chips ---
  Widget _buildReviewSentimentFilter() {
    final sentiments = ['Positive', 'Negative', 'Neutral'];

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: sentiments.map((sentiment) {
        final isSelected = _selectedSentimentFilter == sentiment;

        return ChoiceChip(
          label: Text(sentiment),
          selected: isSelected,
          selectedColor: isSelected
              ? _getSentimentColor(sentiment).withOpacity(0.3)
              : Colors.grey.shade100,
          onSelected: (selected) {
            _setSentimentFilter(selected ? sentiment : null);
          },
        );
      }).toList(),
    );
  }

  // --- Individual Review Tile ---
  Widget _buildReviewTile(Review review) {
    final String sentimentLabel = review.sentimentLabel;
    final double playtime = review.playtimeHours;
    final List<String> tags = review.themeTags;
    final String reviewText = review.reviewText;

    final Color sentimentColor = _getSentimentColor(sentimentLabel);

    return Card(
      elevation: 1,
      margin: const EdgeInsets.symmetric(vertical: 4.0),
      child: ExpansionTile(
        key: PageStorageKey(
          reviewText.substring(0, reviewText.length.clamp(0, 10)),
        ),
        leading: Icon(
          sentimentLabel.toLowerCase() == 'positive'
              ? Icons.thumb_up
              : sentimentLabel.toLowerCase() == 'negative'
                  ? Icons.thumb_down
                  : Icons.chat_bubble_outline,
          color: sentimentColor,
        ),
        title: Text(
          '$sentimentLabel Review',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: sentimentColor,
          ),
        ),
        subtitle: Text(
          'Playtime: ${playtime.toStringAsFixed(1)}h | Themes: ${tags.join(', ')}',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Full Review Text:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  reviewText,
                  style: const TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6.0,
                  children: tags
                      .map(
                        (tag) => Chip(
                          label: Text(
                            tag,
                            style: const TextStyle(fontSize: 10),
                          ),
                          padding: const EdgeInsets.all(2.0),
                        ),
                      )
                      .toList(),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: reviewText));
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Review text copied!'),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- Export/Share Text Summary ---
  void _exportAndShare() {
    if (_analysisResult == null) return;

    final buffer = StringBuffer();
    buffer.writeln(
        '--- Game Review Analysis: ${widget.selectedGame.name} ---');
    buffer.writeln(
        'Scope: Analysis of the most recent $_currentReviewCount reviews.');
    buffer.writeln(
        'Total Themed Reviews Found: $_totalThemedReviewsAvailable\n');

    buffer.writeln('*** Thematic Sentiment Breakdown ***');

    final thematic = _analysisResult!.thematicScores;

    final Map<String, ThemeScore> thematicScoresMap = {
      'length': thematic.length,
      'grind': thematic.grind,
      'value': thematic.value,
    };

    thematicScoresMap.forEach((theme, score) {
      final double positive = score.positivePercent;
      final double negative = score.negativePercent;
      final int found = score.found;

      final verdict = positive >= 60
          ? 'POSITIVE'
          : negative >= 60
              ? 'NEGATIVE'
              : 'MIXED';

      buffer.writeln('- ${theme.toUpperCase()}: $verdict');
      buffer.writeln(
          '  - Positive: ${positive.toStringAsFixed(1)}% ($found reviews)');
    });

    buffer.writeln('\n*** Playtime Distribution ***');
    final playtime = _analysisResult!.playtimeDistribution;
    buffer.writeln(
        'Median Playtime: ${playtime.medianHours.toStringAsFixed(1)} hours');
    buffer.writeln('Interpretation: ${playtime.interpretation}');

    final analysisText = buffer.toString();

    Clipboard.setData(ClipboardData(text: analysisText)).then((_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Analysis summary copied to clipboard!'),
          ),
        );
      }
    });
  }

  // --- Info / Policy / Feedback dialogs (match SearchScreen style) ---

  void _showInfoDialog(BuildContext context, String title, String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Feedback dialog with clickable "here" email link (same as SearchScreen)
  void _showFeedbackDialog() {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Feedback & Contact'),
      content: Text.rich(
        TextSpan(
          style: Theme.of(ctx).textTheme.bodyMedium, // keep normal size
          children: [
            const TextSpan(
              text:
                  'If this app has helped you, or you have recommendations for future features, please contact me ',
            ),
            TextSpan(
              text: 'here',
              style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                    color: Colors.blue,
                    decoration: TextDecoration.underline,
                  ),
              recognizer: TapGestureRecognizer()
                ..onTap = () async {
                  final uri = Uri(
                    scheme: 'mailto',
                    path: 'tom.sbyers93@gmail.com',
                    queryParameters: {
                      'subject': 'Steam Game Analyzer – Feedback',
                    },
                  );
                  await launchUrl(uri);
                },
            ),
            const TextSpan(
              text: '.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}


  // Drawer (hamburger menu) used on this screen
  Widget _buildAppDrawer(BuildContext context) {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
            ),
            child: const Align(
              alignment: Alignment.bottomLeft,
              child: Text(
                'Menu',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),

          // About
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About'),
            onTap: () {
              Navigator.pop(context);
              _showInfoDialog(
                context,
                'About',
                'Steam Game Analyzer is a small research prototype that looks at recent Steam user reviews '
                'and highlights how players talk about time – things like length, grind, and value for time.\n\n'
                'It is built for personal use and academic research, not as a commercial product. The summaries and scores you see '
                'are generated automatically and are not official ratings.\n\n'
                'Steam Game Analyzer is not affiliated with, sponsored by, or endorsed by Valve, Steam, or any game studio or publisher. '
                'All trademarks and game assets remain the property of their respective owners.',
              );
            },
          ),

          // How it works
          ListTile(
            leading: const Icon(Icons.help_outline),
            title: const Text('How it works'),
            onTap: () {
              Navigator.pop(context);
              _showInfoDialog(
                context,
                'How it works',
                'Searching for a game\n\n'
                'Type part or all of a game’s name into the search box and pick the match from the list. '
                'The app uses the public Steam Web API to find games – spellings and regional titles may affect what appears.\n\n'
                'Collecting reviews\n\n'
                'When you open a game’s analysis page, the app asks Steam for up to 1000 of the most recent English-language reviews for that title. '
                'If a game has fewer than 1000 reviews, the analysis uses whatever is available (for example, 22 reviews).\n\n'
                'Time-related reviews only\n\n'
                'The app then scans review text for time-related keywords grouped into three themes:\n\n'
                'Length: hours, playtime, campaign length, etc.\n'
                'Grind: grind, repetitive, chores, time-wasting, etc.\n'
                'Value: worth the time, waste of time, hours of content, etc.\n\n'
                'Only reviews that mention at least one of these themes are shown in the “Filtered Reviews” list. '
                'This is why you may see fewer reviews than the total number collected.\n\n'
                '“Analyse +1000 reviews” button\n\n'
                'Tapping this button tells the backend to re-run the analysis with a higher review target (for example, from 1000 to 2000), '
                'while still respecting Steam’s rate limits and your server’s load.\n\n'
                'If Steam or the server can’t handle a larger batch, the app keeps the last successful analysis instead of crashing, '
                'and shows a message explaining that expansion failed.\n\n'
                'Limits and reliability\n\n'
                'Results depend on what players have written recently on Steam. '
                'The summaries are automatic and may be incomplete or inaccurate, so they should be treated as indicative only, '
                'not as definitive judgments about a game.',
              );
            },
          ),

          const Divider(),

          // Policy & Privacy
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Policy & Privacy'),
            onTap: () {
              Navigator.pop(context);
              _showInfoDialog(
                context,
                'Policy & Privacy',
                'Data & Privacy\n\n'
                'This app does not require an account or login. When you search for a game, the app sends the game name and Steam app ID '
                'to the public Steam Web API to retrieve recent user reviews. Those reviews are processed to detect time-related themes '
                'and basic sentiment.\n\n'
                'Review text and simple summaries may be temporarily cached while the app is running to speed up analysis and export features. '
                'Apart from any standard logs produced by the operating system or development tools, no additional personal data is intentionally '
                'collected or stored by this app.\n\n'
                'Third-Party Services\n\n'
                'The app relies on the public Steam Web API. All game information and reviews are provided by Valve’s services and may change or '
                'be removed at any time. The app does not modify reviews on Steam or interact with your Steam account.\n\n'
                'No Affiliation or Endorsement\n\n'
                'This project is not affiliated with, sponsored by, or endorsed by Valve Corporation, Steam, or any game publisher or developer. '
                'All trademarks are the property of their respective owners.\n\n'
                'No Warranty / Use at Your Own Risk\n\n'
                'The analysis shown in this app is automatically generated and may be incomplete, inaccurate, or misleading. '
                'It is provided “as-is” without any guarantees. Do not rely on it as financial, purchasing, legal, or professional advice.',
              );
            },
          ),

          // Attribution
          ListTile(
            leading: const Icon(Icons.handshake_outlined),
            title: const Text('Attribution'),
            onTap: () {
              Navigator.pop(context);
              _showInfoDialog(
                context,
                'Attribution',
                'Code written with help from Gemini and ChatGPT.\n\n'
                'Steam data © Valve Corporation. All trademarks are property of their respective owners. '
                'This project is not affiliated with or endorsed by Valve or Steam.',
              );
            },
          ),

          const Divider(),

          // Feedback & Contact
          ListTile(
            leading: const Icon(Icons.feedback_outlined),
            title: const Text('Feedback & Contact'),
            onTap: () {
              Navigator.pop(context);
              _showFeedbackDialog();
            },
          ),

          // Buy me a coffee
          ListTile(
            leading: const Icon(Icons.local_cafe_outlined),
            title: const Text('Buy me a coffee'),
            onTap: () {
              Navigator.pop(context);
              _launchExternalUrl(_buyMeACoffeeUrl);
            },
          ),
        ],
      ),
    );
  }

  // --- Main Build Method ---
  @override
  Widget build(BuildContext context) {
    final nextReviewCount = _currentReviewCount + 1000;
    final reviewsToDisplay = _filteredReviews;

    // 1. Still loading – just show spinner
    if (_isLoadingAnalysis) {
      return Scaffold(
        appBar: AppBar(
          title: Text('Analysis for ${widget.selectedGame.name}'),
          backgroundColor: Theme.of(context).colorScheme.primary,
          foregroundColor: Theme.of(context).colorScheme.onPrimary,
        ),
        drawer: _buildAppDrawer(context),
        bottomNavigationBar: Container(
          height: 20,
          alignment: Alignment.center,
          color: Colors.grey.shade200,
          child: const Text(
            'Code written by Gemini and ChatGPT',
            style: TextStyle(fontSize: 10, color: Colors.grey),
          ),
        ),
        body: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 20),
              Text('Analyzing reviews...'),
            ],
          ),
        ),
      );
    }

    // 2. We have no analysis object at all – show error / empty state.
    if (_analysisResult == null) {
      return Scaffold(
        appBar: AppBar(
          title: Text('Analysis for ${widget.selectedGame.name}'),
          backgroundColor: Theme.of(context).colorScheme.primary,
          foregroundColor: Theme.of(context).colorScheme.onPrimary,
        ),
        drawer: _buildAppDrawer(context),
        bottomNavigationBar: Container(
          height: 20,
          alignment: Alignment.center,
          color: Colors.grey.shade200,
          child: const Text(
            'Code written by Gemini and ChatGPT',
            style: TextStyle(fontSize: 10, color: Colors.grey),
          ),
        ),
        body: Center(
          child: Text(_error ?? 'No analysis available for this game yet.'),
        ),
      );
    }

    // 3. Normal case – we have an AnalysisResult, always show playtime etc.
    final analysis = _analysisResult!;

    return Scaffold(
      appBar: AppBar(
        title: Text('Analysis for ${widget.selectedGame.name}'),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            onPressed: _exportCSVData,
            tooltip: 'Export All Themed Reviews to CSV',
          ),
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: _exportAndShare,
            tooltip: 'Copy Analysis Summary to Clipboard',
          ),
        ],
      ),
      drawer: _buildAppDrawer(context),
      bottomNavigationBar: Container(
        height: 20,
        alignment: Alignment.center,
        color: Colors.grey.shade200,
        child: const Text(
          'Code written by Gemini and ChatGPT',
          style: TextStyle(fontSize: 10, color: Colors.grey),
        ),
      ),
      body: ListView(
        controller: _scrollController,
        padding: const EdgeInsets.all(16.0),
        children: [
          // Optional inline error message if last "add 1000" failed
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.red),
                textAlign: TextAlign.center,
              ),
            ),

          // --- 1. Button to add 1000 more ---
          Center(
            child: ElevatedButton.icon(
              onPressed: () => _fetchAnalysisData(
                reviewCount: nextReviewCount,
                allowRollback: true,
              ),
              icon: const Icon(Icons.add_circle_outline),
              label: Text(
                'Analyze $nextReviewCount Reviews (Add 1000 More)',
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade700,
                foregroundColor: Colors.white,
              ),
            ),
          ),
          const Divider(height: 32),

          // --- 2. Total counts (use reviewCountUsed so <1000 is correct) ---
          ListTile(
            leading: const Icon(
              Icons.insights,
              color: Colors.deepPurple,
              size: 30,
            ),
            title: const Text(
              'Analysis Scope',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            trailing: Text(
              '${analysis.reviewCountUsed} Reviews',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.deepPurple,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(
              Icons.list_alt,
              color: Colors.grey,
              size: 30,
            ),
            title: const Text(
              'Themed Reviews Available',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            trailing: Text(
              '$_totalThemedReviewsAvailable',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
          ),
          const Divider(height: 32),

          // --- 3. Playtime Distribution (always shown) ---
          Text(
            'Playtime Distribution Analysis',
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          _buildPlaytimeChart(analysis.playtimeDistribution),
          const Divider(height: 32),

          // --- 4. Thematic Sentiment cards ---
          Text(
            'Thematic Sentiment Breakdown (Tap to Filter)',
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Expanded(
                child: _buildThematicScoreCard(
                  'length',
                  analysis.thematicScores.length,
                ),
              ),
              Expanded(
                child: _buildThematicScoreCard(
                  'grind',
                  analysis.thematicScores.grind,
                ),
              ),
              Expanded(
                child: _buildThematicScoreCard(
                  'value',
                  analysis.thematicScores.value,
                ),
              ),
            ],
          ),
          const Divider(height: 32),

          // --- 5. Reviews section ---
          if (_totalThemedReviewsAvailable == 0) ...[
            Text(
              'No time-centric reviews found',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Playtime distribution above is still based on all available reviews.',
              textAlign: TextAlign.center,
            ),
          ] else ...[
            Text(
              'Filtered Reviews (${reviewsToDisplay.length} shown)',
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            _buildReviewSentimentFilter(),
            const SizedBox(height: 16),
            ...reviewsToDisplay.map(_buildReviewTile),
            if (_isLoadingReviews)
              const Padding(
                padding: EdgeInsets.all(8.0),
                child: Center(
                  child: CircularProgressIndicator(),
                ),
              ),
            if (!_hasMoreReviews && _reviews.isNotEmpty)
              const Padding(
                padding: EdgeInsets.all(8.0),
                child: Center(
                  child: Text('--- End of Themed Reviews ---'),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
