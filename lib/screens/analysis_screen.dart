// lib/screens/analysis_screen.dart

import 'package:flutter/foundation.dart' show kIsWeb;
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

const String _buyMeACoffeeUrl = 'https://www.buymeacoffee.com/tbbye';

// OPTIONAL: your GitHub repo (add your real link here)
const String _githubUrl = 'https://github.com/tbbye/Temporal-Satisfaction';


// --- Tighter spacing constants ---
const double kGapXS = 6;
const double kGapS = 8; // tighter overall
const double kGapM = 12;

// --- Slightly stronger elevation everywhere (requested) ---
const double kElevLow = 2.5;
const double kElevMed = 4;

// --- Header title helper: "(game)’s STS Profile" (safe for long titles) ---
String stsHeaderTitle(String gameName) {
  final trimmed = gameName.trim();
  if (trimmed.isEmpty) return 'STS Profile';
  final lower = trimmed.toLowerCase();
  final possessive = lower.endsWith('s') ? '’' : '’s';
  return '$trimmed$possessive STS Profile';
}
Future<void> _launchGithub() async {
  final uri = Uri.parse(_githubUrl);
  if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
    // ignore: avoid_print
    print('Could not launch $_githubUrl');
  }
}

Future<void> _launchExternalUrl(String url) async {
  final Uri uri = Uri.parse(url);
  if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
    // ignore: avoid_print
    print('Could not launch $url');
  }
}

// --- faint grid painter for the playtime chart box ---
class _GridLinePainter extends CustomPainter {
  final int lines;
  final double opacity;

  _GridLinePainter({this.lines = 4, this.opacity = 0.12});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black.withValues(alpha: opacity)
      ..strokeWidth = 1;

    if (lines <= 0) return;
    for (int i = 1; i <= lines; i++) {
      final y = size.height * (i / (lines + 1));
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridLinePainter oldDelegate) {
    return oldDelegate.lines != lines || oldDelegate.opacity != opacity;
  }
}

class AnalysisScreen extends StatefulWidget {
  final Game selectedGame;

  final String baseUrl = kIsWeb
      ? "https://temporal-satisfaction.onrender.com"
      : "http://127.0.0.1:5000";

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

  String get _steamStoreUrl =>
      'https://store.steampowered.com/app/${widget.selectedGame.appid}/';

  bool _isMissingOrNA(String? s) {
    if (s == null) return true;
    final v = s.trim();
    if (v.isEmpty) return true;
    final upper = v.toUpperCase();
    return upper == 'NA' || upper == 'N/A' || upper == 'NONE' || upper == 'NULL';
  }

  Future<void> _fetchAnalysisData({
    required int reviewCount,
    bool allowRollback = false,
  }) async {
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

  void _setThemeFilter(String theme) {
    setState(() {
      _selectedThemeFilter = (_selectedThemeFilter == theme) ? null : theme;
    });
  }

  void _setSentimentFilter(String? sentiment) {
    setState(() {
      _selectedSentimentFilter = sentiment;
    });
  }

  // --- Export CSV Logic (Web vs Android) ---
  Future<void> _exportCSVData() async {
    if (_analysisResult == null) return;

    final exportUrl =
        '${widget.baseUrl}/export?app_id=${widget.selectedGame.appid}&total_count=${_analysisResult!.reviewCountUsed}';

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Preparing export...')),
    );

    try {
      if (kIsWeb) {
        await launchUrl(Uri.parse(exportUrl),
            mode: LaunchMode.externalApplication);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Export started in browser.')),
        );
        return;
      }

      final response = await http.get(Uri.parse(exportUrl));

      if (response.statusCode == 200) {
        final bytes = response.bodyBytes;
        final fileName =
            'sts_export_${widget.selectedGame.appid}_${DateTime.now().millisecondsSinceEpoch}.csv';

        await FileSaver.instance.saveFile(
          name: fileName,
          bytes: bytes,
          ext: 'csv',
          mimeType: MimeType.csv,
        );

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exported to $fileName')),
        );
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed (${response.statusCode})')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export error: $e')),
      );
    }
  }

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

  // ---------- Game header (Store page button directly next to game title; release year with dev/pub) ----------
  Widget _buildGameHeaderCard() {
    final String gameName = widget.selectedGame.name;
    final String headerImageUrl = widget.selectedGame.headerImageUrl;

    // Safe dynamic access
    String? developer;
    String? publisher;
    String? releaseDate;
    try {
      developer = (widget.selectedGame as dynamic).developer as String?;
    } catch (_) {}
    try {
      publisher = (widget.selectedGame as dynamic).publisher as String?;
    } catch (_) {}
    try {
      releaseDate = (widget.selectedGame as dynamic).releaseDate as String?;
    } catch (_) {}

    final bool showDev = !_isMissingOrNA(developer);
    final bool showPub = !_isMissingOrNA(publisher);
    final bool showRelease = !_isMissingOrNA(releaseDate);

    // release year (keeps it compact with dev/pub)
    String? releaseYear;
    if (showRelease) {
      final rd = releaseDate!.trim();
      // grabs first 4-digit year if present
      final m = RegExp(r'(\d{4})').firstMatch(rd);
      releaseYear = m?.group(1) ?? rd;
    }

    final labelStyle = const TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w800,
      color: Colors.black87,
    );
    final valueStyle = const TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      color: Colors.black87,
    );
    // --- helper: uniform label/value alignment ---
    Widget metaRow({
      required String label,
      required List<InlineSpan> valueSpans,
    }) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 92, // tweak 86–110 if you want tighter/looser label column
              child: Text(label, style: labelStyle),
            ),
            Expanded(
              child: Text.rich(
                TextSpan(style: valueStyle, children: valueSpans),
              ),
            ),
          ],
        ),
      );
    }

    return Card(
      elevation: kElevMed,
      color: Colors.white,
      surfaceTintColor: Colors.white,
      margin: const EdgeInsets.only(bottom: kGapS),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
                color: Colors.grey.shade100,
                child: AspectRatio(
                  aspectRatio: 460 / 215,
                  child: (headerImageUrl.trim().isNotEmpty)
                      ? Image.network(
                          headerImageUrl,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => const Center(
                            child: Icon(Icons.image_not_supported),
                          ),
                        )
                      : const Center(
                          child: Icon(Icons.videogame_asset, size: 34),
                        ),
                ),
              ),
            ),
            const SizedBox(height: kGapS),

            // Title + Store page (right)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    gameName,
                    style: const TextStyle(
  fontSize: 20, // was 18
  fontWeight: FontWeight.w900, // slightly punchier
  height: 1.08, // keeps multi-line titles tighter
),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 10),
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: ElevatedButton.icon(
                    onPressed: () => _launchExternalUrl(_steamStoreUrl),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('Store page'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 15,
                        vertical: 15,
                      ),
                      minimumSize: const Size(0, 0),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: kGapXS),

                        // Dev + Pub (single line)
            if (showDev || showPub)
              Text.rich(
                TextSpan(
                  children: [
                    if (showDev) ...[
                      TextSpan(text: 'Developer: ', style: labelStyle),
                      TextSpan(text: developer!.trim(), style: valueStyle),
                    ],
                    if (showDev && showPub) const TextSpan(text: '      '),
                    if (showPub) ...[
                      TextSpan(text: 'Publisher: ', style: labelStyle),
                      TextSpan(text: publisher!.trim(), style: valueStyle),
                    ],
                  ],
                ),
              ),

            const SizedBox(height: kGapXS),

            // Released + Steam AppID (same line)
            Text.rich(
              TextSpan(
                children: [
                  if (showRelease && releaseYear != null) ...[
                    TextSpan(text: 'Released: ', style: labelStyle),
                    TextSpan(text: releaseYear, style: valueStyle),
                    const TextSpan(text: '      '),
                  ],
                  TextSpan(text: 'Steam AppID: ', style: labelStyle),
                  TextSpan(
                    text: '${widget.selectedGame.appid}',
                    style: valueStyle,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }


  // ---------- Compact scope row (white background; slightly more shadow) ----------
  Widget _buildCompactScopeRow({
    required int reviewCountUsed,
    required int themedReviewsAvailable,
  }) {
    Widget pill({
      required IconData icon,
      required String label,
      required String value,
    }) {
      return Expanded(
        child: Card(
          elevation: kElevLow,
          color: Colors.white,
          surfaceTintColor: Colors.white,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.grey.shade300),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
            child: Row(
              children: [
                Icon(icon, size: 18, color: Colors.blueGrey.shade700),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Colors.blueGrey.shade700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        value,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        pill(
          icon: Icons.insights,
          label: 'Analysis scope',
          value: '$reviewCountUsed reviews',
        ),
        const SizedBox(width: 10),
        pill(
          icon: Icons.list_alt,
          label: 'Themed reviews found',
          value: '$themedReviewsAvailable',
        ),
      ],
    );
  }

  // ---------- Playtime distribution card (boxed + faint grid + stronger shadow) ----------
  Widget _buildPlaytimeDistributionCard(PlaytimeDistribution distribution) {
    final List<double> buckets = distribution.histogramBuckets;
    final double maxBucketValue =
        buckets.isEmpty ? 0 : buckets.reduce((a, b) => a > b ? a : b);

    final List<String> labels = [
      '<1h',
      '1–5h',
      '5–10h',
      '10–20h',
      '20–50h',
      '50–100h',
      '100h+',
    ];

    final int reviewCountUsed =
        _analysisResult?.reviewCountUsed ?? _currentReviewCount;
    final double medianHours = distribution.medianHours;
    final String gameName = widget.selectedGame.name;

    return Card(
      elevation: kElevMed,
      color: Colors.white,
      surfaceTintColor: Colors.white,
      margin: const EdgeInsets.only(top: kGapS, bottom: kGapM),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(5, 5, 5, 5),
        child: Column(
          children: [
            Text(
  'Playtime Distribution',
  textAlign: TextAlign.center,
  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w900,
      ),
),
            const SizedBox(height: kGapS),
            SizedBox(
              height: 135,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _GridLinePainter(lines: 4, opacity: 0.10),
                    ),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: buckets.asMap().entries.map((entry) {
                        final int index = entry.key;
                        final double value = entry.value;
                        final double height = maxBucketValue > 0
                            ? (value / maxBucketValue) * 100.0
                            : 0.0;

                        final String label =
                            (index >= 0 && index < labels.length)
                                ? labels[index]
                                : '';

                        return Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text('${value.toInt()}',
                                style: const TextStyle(fontSize: 10)),
                            Container(
                              width: 20,
                              height: height.clamp(0, 100),
                              color: Colors.lightBlue.shade300,
                            ),
                            const SizedBox(height: 4),
                            SizedBox(
                              width: 44,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  label,
                                  maxLines: 1,
                                  softWrap: false,
                                  overflow: TextOverflow.visible,
                                  style: const TextStyle(fontSize: 10),
                                ),
                              ),
                            ),
                          ],
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 2),

Padding(
  padding: const EdgeInsets.symmetric(horizontal: 8.0),
  child: Column(
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'Median total playtime',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: Colors.black87,
            ),
          ),
          const SizedBox(width: 3),
          GestureDetector(
            onTap: () {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Median total playtime'),
                  content: Text(
                    'Based on the total playtime of each user from the $reviewCountUsed most recent reviews collected for this analysis (not all reviews on Steam).',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              );
            },
            child: Tooltip(
              message:
                  'Based on the total playtime of each user from the $reviewCountUsed most recent reviews collected for this analysis (not all reviews on Steam).',
              child: const Text(
                '*',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  color: Colors.black,
                ),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 1),
      TweenAnimationBuilder<double>(
        tween: Tween<double>(
          begin: 0.0,
          end: medianHours.isNaN ? 0.0 : medianHours,
        ),
        duration: const Duration(milliseconds: 1800),
        curve: Curves.easeOutCubic,
        builder: (context, value, child) {
          return Text(
            medianHours.isNaN ? 'N/A' : '${value.toStringAsFixed(1)}h',
            style: const TextStyle(
              fontSize: 36,
              fontWeight: FontWeight.w900,
              color: Colors.green,
            ),
            textAlign: TextAlign.center,
          );
        },
      ),
    ],
  ),
),
// REMOVED: const SizedBox(height: kGapXS),
// REMOVED: Text(
// REMOVED:   'Based on the total playtime of the each user from the $reviewCountUsed most recent reviews collected for this analysis (not all reviews on Steam).',
// REMOVED:   textAlign: TextAlign.center,
// REMOVED:   style: const TextStyle(fontSize: 12, color: Colors.black87),
// REMOVED: ),
],
),
),
);
}

  Widget _buildThematicScoreCard(String theme, ThemeScore score) {
  final isSelected = _selectedThemeFilter == theme;

  final String title = theme.toUpperCase();
  late final String verdict;
  late final Color color;

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
      surfaceTintColor: Colors.white,
      elevation: kElevMed,
      margin: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 12, 10, 10), // slightly tighter
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              '$title\nSENTIMENT',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 15, // slightly smaller
                height: 1.1,
              ),
            ),
            const SizedBox(height: 6),

            // Verdict: force single line, smaller so "NEGATIVE" never wraps
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                verdict,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                  fontSize: 20, // smaller than before
                  fontWeight: FontWeight.w900,
                  color: color,
                  height: 1.0,
                ),
              ),
            ),

            const SizedBox(height: 6),

            // Stats: ALWAYS two lines (no "|")
            Text(
              found == 0 ? '—' : '${positive.toStringAsFixed(1)}% Positive',
              textAlign: TextAlign.center,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 2),
            Text(
              found == 0 ? '0 reviews' : '$found reviews',
              textAlign: TextAlign.center,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),

            if (isSelected)
              const Padding(
                padding: EdgeInsets.only(top: 4.0),
                child: Text(
                  'FILTER ACTIVE',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 10, color: Colors.blue),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}


  // ---------- Sentiment filter chips (white background + border) ----------
  Widget _buildReviewSentimentFilter() {
    final sentiments = ['Positive', 'Negative', 'Neutral'];

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: sentiments.map((sentiment) {
        final isSelected = _selectedSentimentFilter == sentiment;
        final c = _getSentimentColor(sentiment);

        return ChoiceChip(
          label: Text(sentiment),
          selected: isSelected,
          backgroundColor: Colors.white,
          selectedColor: Colors.white,
          shape: StadiumBorder(
            side: BorderSide(
              color: isSelected ? c : Colors.grey.shade300,
              width: isSelected ? 2 : 1,
            ),
          ),
          labelStyle: TextStyle(
            color: Colors.black87,
            fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
          ),
          onSelected: (selected) {
            _setSentimentFilter(selected ? sentiment : null);
          },
        );
      }).toList(),
    );
  }

  Widget _buildReviewTile(Review review) {
  final String sentimentLabel = review.sentimentLabel;
  final double playtime = review.playtimeHours;
  final List<String> tags = review.themeTags;
  final String reviewText = review.reviewText;

  final Color sentimentColor = _getSentimentColor(sentimentLabel);

  return Card(
    elevation: kElevLow,
    color: Colors.white,
    surfaceTintColor: Colors.white,
    margin: const EdgeInsets.symmetric(vertical: 4.0),
    child: ExpansionTile(
      key: PageStorageKey(
        reviewText.substring(0, reviewText.length.clamp(0, 10)),
      ),

      // --- Hide the black divider line (expanded + collapsed) ---
      shape: const Border(),
      collapsedShape: const Border(),

      // --- Keep tile background clean white ---
      backgroundColor: Colors.white,
      collapsedBackgroundColor: Colors.white,

      // Optional: keep padding tidy (also helps avoid odd edge artefacts)
      tilePadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 0),
      childrenPadding: EdgeInsets.zero,

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
                        label: Text(tag, style: const TextStyle(fontSize: 10)),
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
                        const SnackBar(content: Text('Review text copied!')),
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


  void _exportAndShare() {
    if (_analysisResult == null) return;

    final buffer = StringBuffer();
    buffer.writeln('--- STS Profiles: ${widget.selectedGame.name} ---');
    buffer.writeln(
        'Scope: Analysis of the most recent $_currentReviewCount reviews.');
    buffer.writeln('Total Themed Reviews Found: $_totalThemedReviewsAvailable\n');

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

    final playtime = _analysisResult!.playtimeDistribution;
    buffer.writeln('\n*** Playtime Distribution (All collected reviews) ***');
    buffer.writeln(
      'Median total playtime: ${playtime.medianHours.isNaN ? 'N/A' : playtime.medianHours.toStringAsFixed(1)}h',
    );
    buffer.writeln(
      'Note: This is total hours recorded for the reviewer at the time they posted/updated the review.',
    );

    final analysisText = buffer.toString();

    Clipboard.setData(ClipboardData(text: analysisText)).then((_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Analysis summary copied to clipboard!')),
        );
      }
    });
  }

  void _showRichInfoDialog(
    BuildContext context,
    String title,
    List<TextSpan> spans,
  ) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Text.rich(
            TextSpan(
              style: Theme.of(ctx).textTheme.bodyMedium,
              children: spans,
            ),
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

  void _showFeedbackDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Feedback & Contact'),
        content: Text.rich(
          TextSpan(
            style: Theme.of(ctx).textTheme.bodyMedium,
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
                        'subject': 'STS Profiles – Feedback',
                      },
                    );
                    await launchUrl(uri);
                  },
              ),
              const TextSpan(text: '.'),
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

  Drawer _buildAppDrawer(BuildContext context) {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: const BoxDecoration(
              color: Colors.black, // was theme primary (blue) – now black
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
          ListTile(
  leading: const Icon(Icons.info_outline),
  title: const Text('About'),
  onTap: () {
    Navigator.pop(context);
    _showRichInfoDialog(
      context,
      'About',
      [
        const TextSpan(
          text: 'STS Profiles\n',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const TextSpan(text: '(Steam Temporal Satisfaction Profiles)\n'),
        const TextSpan(
          text: 'A snapshot of how players evaluate time in play.\n\n',
          style: TextStyle(fontStyle: FontStyle.italic),
        ),
        const TextSpan(
          text: 'What it does\n',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const TextSpan(
          text:
              'This is a small research prototype that looks at recent Steam user reviews and highlights how players talk about time – things like length, grind, and value for time.\n\n',
        ),
        const TextSpan(
          text: 'Important\n',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const TextSpan(
          text:
              'Summaries and sentiment are generated automatically and are indicative only – not official ratings.\n\n',
        ),
        const TextSpan(
          text: 'Source code\n',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const TextSpan(
          text: 'If you want to inspect the code or report issues, the source is available on ',
        ),
        TextSpan(
          text: 'GitHub',
          style: const TextStyle(
            color: Colors.blue,
            decoration: TextDecoration.underline,
            fontWeight: FontWeight.w700,
          ),
          recognizer: TapGestureRecognizer()..onTap = _launchGithub,
        ),
        const TextSpan(text: '.\n\n'),
        const TextSpan(
          text: 'No affiliation\n',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const TextSpan(
          text:
              'STS Profiles is not affiliated with, sponsored by, or endorsed by Valve, Steam, or any game studio or publisher. All trademarks remain the property of their respective owners.',
        ),
      ],
    );
  },
),

          ListTile(
  leading: const Icon(Icons.help_outline),
  title: const Text('How it works'),
  onTap: () {
    Navigator.pop(context);
    _showRichInfoDialog(
      context,
      'How it works',
      [
        const TextSpan(
          text: 'Searching for a game\n',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const TextSpan(
          text:
              'Type part or all of a game’s name into the search box and pick a match from the list. The app uses the public Steam Web API to find games – spellings and regional titles may affect what appears.\n\n',
        ),
        const TextSpan(
          text: 'Collecting reviews\n',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const TextSpan(
          text:
              'When you open a game’s analysis page, the app asks Steam for up to a target number of the most recent English-language reviews for that title. If a game has fewer reviews available, the analysis uses whatever is returned.\n\n',
        ),
        const TextSpan(
          text: 'Time-related reviews only\n',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const TextSpan(
          text:
              'The app scans review text for time-related keywords grouped into three themes: Length, Grind, and Value. Only reviews that mention at least one theme are shown in the filtered list.\n\n',
        ),
        const TextSpan(
          text: 'Sentiment scope\n',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const TextSpan(
          text:
              'Sentiment reflects the time-related parts of a review, not the overall recommendation.\n\n',
        ),
        const TextSpan(
          text: 'Limits and reliability\n',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const TextSpan(
          text:
              'Results depend on what players have written recently on Steam. The analysis may be incomplete or inaccurate – treat it as indicative.\n\n',
        ),
        const TextSpan(
          text:
              'Automated sentiment can miss context (for example sarcasm, jokes, mixed opinions, or broader complaints that sound “negative” but are not about time). If something looks off, open the full review list and treat the profile as a starting point rather than a verdict.',
        ),
      ],
    );
  },
),

          const Divider(),
          ListTile(
            leading: const Icon(Icons.policy),
            title: const Text('Policy & Privacy'),
            onTap: () {
              Navigator.pop(context);
              _showRichInfoDialog(
                context,
                'Policy & Privacy',
                [
                  const TextSpan(
                    text: 'Data & Privacy\n',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const TextSpan(
                    text:
                        'This app does not require an account or login. When you search for a game, the app sends the game name and Steam app ID to the public Steam Web API to retrieve recent user reviews.\n\n',
                  ),
                  const TextSpan(
                    text: 'Third-party services\n',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const TextSpan(
                    text:
                        'The app relies on Valve’s public Steam Web API. Content may change or be removed at any time.\n\n',
                  ),
                  const TextSpan(
                    text: 'No affiliation\n',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const TextSpan(
                    text:
                        'This project is not affiliated with, sponsored by, or endorsed by Valve Corporation or Steam.\n\n',
                  ),
                  const TextSpan(
                    text: 'No warranty\n',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const TextSpan(
                    text:
                        'The analysis is provided “as-is” without guarantees and should not be treated as professional advice.',
                  ),
                ],
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.favorite_outline),
            title: const Text('Attribution'),
            onTap: () {
              Navigator.pop(context);
              _showRichInfoDialog(
                context,
                'Attribution',
                [
                  const TextSpan(
                    text: 'Code\n',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const TextSpan(
                    text: 'Code written with help from Gemini and ChatGPT.\n\n',
                  ),
                  const TextSpan(
                    text: 'Steam data\n',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const TextSpan(
                    text:
                        'Steam data © Valve Corporation. All trademarks are property of their respective owners.',
                  ),
                ],
              );
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.feedback_outlined),
            title: const Text('Feedback & Contact'),
            onTap: () {
              Navigator.pop(context);
              _showFeedbackDialog();
            },
          ),
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

  @override
  Widget build(BuildContext context) {
    final nextReviewCount = _currentReviewCount + 1000;
    final reviewsToDisplay = _filteredReviews;
    final String pageTitle = stsHeaderTitle(widget.selectedGame.name);

    AppBar buildTopBar({bool showActions = true}) {
      return AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
  pageTitle,
  maxLines: 1,
  overflow: TextOverflow.ellipsis,
  style: const TextStyle(fontWeight: FontWeight.w900),
),
        automaticallyImplyLeading: true,
        actions: [
          if (showActions) ...[
            IconButton(
              icon: const Icon(Icons.download),
              onPressed: _exportCSVData,
              tooltip: 'Export all themed reviews to CSV',
            ),
            IconButton(
              icon: const Icon(Icons.share),
              onPressed: _exportAndShare,
              tooltip: 'Copy analysis summary to clipboard',
            ),
          ],
          Builder(
            builder: (ctx) => IconButton(
              icon: const Icon(Icons.menu),
              tooltip: 'Menu',
              onPressed: () => Scaffold.of(ctx).openEndDrawer(),
            ),
          ),
        ],
      );
    }

    if (_isLoadingAnalysis) {
      return Scaffold(
        backgroundColor: Colors.white,
        appBar: buildTopBar(showActions: false),
        endDrawer: _buildAppDrawer(context),
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
              Text('Analysing reviews...'),
            ],
          ),
        ),
      );
    }

    if (_analysisResult == null) {
      return Scaffold(
        backgroundColor: Colors.white,
        appBar: buildTopBar(showActions: false),
        endDrawer: _buildAppDrawer(context),
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

    final analysis = _analysisResult!;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: buildTopBar(),
      endDrawer: _buildAppDrawer(context),
      bottomNavigationBar: Container(
        height: 20,
        alignment: Alignment.center,
        color: Colors.grey.shade200,
        child: const Text(
          'Code written by Gemini and ChatGPT',
          style: TextStyle(fontSize: 10, color: Colors.grey),
        ),
      ),

      // White background + black text (requested)
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isLoadingAnalysis
            ? null
            : () => _fetchAnalysisData(
                  reviewCount: nextReviewCount,
                  allowRollback: true,
                ),
        icon: const Icon(Icons.add, size: 18, color: Colors.white),
        label: const Text(
          'Add 1000 more reviews',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        elevation: 5,
        extendedPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,

      body: ListView(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: kGapS),
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.red),
                textAlign: TextAlign.center,
              ),
            ),

          _buildGameHeaderCard(),

          _buildCompactScopeRow(
            reviewCountUsed: analysis.reviewCountUsed,
            themedReviewsAvailable: _totalThemedReviewsAvailable,
          ),

          // LESS SPACE here (requested)
          const SizedBox(height: 6),

          _buildPlaytimeDistributionCard(analysis.playtimeDistribution),

          const SizedBox(height: 2),

          Center(
  child: GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Sentiment scope'),
          content: const Text(
            'Sentiment reflects the time-related parts of a review, not the overall recommendation.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    },
    child: Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
  'Thematic Sentiment Breakdown',
  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w900,
      ),
  textAlign: TextAlign.center,
),
        const SizedBox(width: 2), // tighter than 6
        // Optional: nudge up slightly if you still feel it's low
        Transform.translate(
  offset: const Offset(0, -12), // increase to -7/-8 if you want it higher
  child: const Text(
    '*',
    style: TextStyle(
      fontSize: 14,          // slightly smaller feels more “superscript”
      fontWeight: FontWeight.w900,
      color: Colors.black87,
      height: 1,
    ),
  ),
),
      ],
    ),
  ),
),


const SizedBox(height: 6),


          const SizedBox(height: 1),

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
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

          const SizedBox(height: kGapS),

          if (_totalThemedReviewsAvailable == 0) ...[
            const SizedBox(height: 4),
            Text(
              'No time-centric reviews found',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: kGapXS),
            const Text(
              'Try increasing the analysis scope, or check a different game.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.black87),
            ),
          ] else ...[
            _buildReviewSentimentFilter(),
            const SizedBox(height: kGapXS),
            Text(
              'Tap a theme (Length, Grind, Value) or sentiment (Positve, Negative, Neutral) to filter the reviews below. Tap again to clear.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                    color: Colors.black,
                  ),
            ),
            const SizedBox(height: kGapS),

            ...reviewsToDisplay.map(_buildReviewTile),

            if (_isLoadingReviews)
              const Padding(
                padding: EdgeInsets.all(8.0),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (!_hasMoreReviews && _reviews.isNotEmpty)
              const Padding(
                padding: EdgeInsets.all(8.0),
                child: Center(child: Text('--- End of Themed Reviews ---')),
              ),
          ],
        ],
      ),
    );
  }
}
