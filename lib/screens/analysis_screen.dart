// lib/screens/analysis_screen.dart

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../models/analysis_result.dart';
import '../models/game.dart';
import '../models/playtime_distribution.dart';
import '../models/review.dart';
import '../services/api_service.dart';

const String _buyMeACoffeeUrl = 'https://www.buymeacoffee.com/tbbye';
const String _githubUrl = 'https://github.com/tbbye/Temporal-Satisfaction';

// --- Web layout tuning ---
const double kWebMaxWidth = 860;

// --- Tighter spacing constants ---
const double kGapXS = 6;
const double kGapS = 8;
const double kGapM = 12;

// --- Slightly stronger elevation everywhere ---
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

  // --- Visible screenshot capture (optional) ---
  final GlobalKey _pageCaptureKey = GlobalKey();

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

  // --- Web: constrain width without vertically centring (prevents weird top gaps) ---
  Widget _webConstrain(Widget child) {
    if (!kIsWeb) return child;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kWebMaxWidth),
        child: child,
      ),
    );
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

  // --- Export CSV Logic (do not touch) ---
  Future<void> _exportCSVData() async {
    if (_analysisResult == null) return;

    final exportUrl =
        '${widget.baseUrl}/export?app_id=${widget.selectedGame.appid}&total_count=${_analysisResult!.reviewCountAnalyzed}';

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
            'sts_export_${widget.selectedGame.appid}_${DateTime.now().millisecondsSinceEpoch}';

        await FileSaver.instance.saveFile(
          name: fileName,
          bytes: bytes,
          ext: 'csv',
          mimeType: MimeType.csv,
        );

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exported to $fileName.csv')),
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

  // --- Install to Home Screen (exact same text as SearchScreen) ---
  void _showInstallToHomeScreenDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Install on home screen'),
        content: const Text(
          'Android (Chrome):\n'
          '1) Tap the ⋮ menu (top-right)\n'
          '2) Tap “Install app” or “Add to Home screen”\n\n'
          'iPhone/iPad (Safari):\n'
          '1) Tap Share\n'
          '2) Tap “Add to Home Screen”\n\n'
          'If you don’t see install options, it usually means the app isn’t being served over HTTPS, '
          'or the browser doesn’t consider it installable yet.',
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

  // --- Banner image that looks good on wide web screens ---
  Widget _buildNiceHeaderImage(String url) {
    if (url.trim().isEmpty) {
      return Container(
        height: 180,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.grey.shade200,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.videogame_asset, size: 34),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: 460 / 215,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.network(
              url,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.high,
              errorBuilder: (context, error, stackTrace) =>
                  Container(color: Colors.grey.shade200),
            ),
            BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(color: Colors.black.withValues(alpha: 0.12)),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Image.network(
                url,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
                errorBuilder: (context, error, stackTrace) => const Center(
                  child: Icon(Icons.image_not_supported),
                ),
              ),
            ),

            // Steam chip overlay
            Positioned(
              right: 10,
              bottom: 10,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => _launchExternalUrl(_steamStoreUrl),
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.25),
                      ),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.open_in_new, size: 16, color: Colors.white),
                        SizedBox(width: 6),
                        Text(
                          'Steam page',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==========================
  // SHARE (FIXED)
  // ==========================

  String _buildShareUrlForGame() {
    final base = Uri.base;

    final params = <String, String>{
      'appid': widget.selectedGame.appid,
      'name': widget.selectedGame.name,
    };

    // Support hash routing: keep fragment route and append query
    if (base.fragment.isNotEmpty) {
      final frag = base.fragment;
      final fragBase = frag.contains('?') ? frag.split('?').first : frag;
      final q = Uri(queryParameters: params).query;
      return base.replace(fragment: '$fragBase?$q').toString();
    }

    // Normal query routing: merge with existing params
    final merged = Map<String, String>.from(base.queryParameters)..addAll(params);
    return base.replace(queryParameters: merged).toString();
  }

  Future<void> _copyShareLink() async {
    final url = _buildShareUrlForGame();
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Share link copied.')),
    );
  }

  String _safeFileStem() {
    final safeName = widget.selectedGame.name
        .trim()
        .replaceAll(RegExp(r'[^\w]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    return 'STS_${widget.selectedGame.appid}_$safeName';
  }

  // Render a full “poster” widget off-screen and capture it as PNG (reliable).
  Future<Uint8List> _renderPosterPng(Widget poster) async {
    final key = GlobalKey();
    final overlay = Overlay.of(context, rootOverlay: true);
    if (overlay == null) throw Exception('Overlay not available');

    final entry = OverlayEntry(
      builder: (context) => Positioned(
        left: -10000,
        top: -10000,
        child: Material(
          type: MaterialType.transparency,
          child: RepaintBoundary(
            key: key,
            child: SizedBox(
              width: 1080,
              child: poster,
            ),
          ),
        ),
      ),
    );

    overlay.insert(entry);

    await Future.delayed(const Duration(milliseconds: 50));
    await WidgetsBinding.instance.endOfFrame;

    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;

    final image = await boundary.toImage(pixelRatio: 2.0);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);

    entry.remove();

    if (byteData == null) throw Exception('PNG capture failed');
    return byteData.buffer.asUint8List();
  }

  Future<void> _savePngBytes(Uint8List bytes, String filenameStem) async {
    await FileSaver.instance.saveFile(
      name: filenameStem,
      bytes: bytes,
      ext: 'png',
      mimeType: MimeType.png,
    );
  }

  Future<void> _exportPosterPng() async {
    final a = _analysisResult;
    if (a == null) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Rendering poster…')),
    );

    final poster = _buildPosterWidget(a);
    final bytes = await _renderPosterPng(poster);

    final stem = '${_safeFileStem()}_poster';
    await _savePngBytes(bytes, stem);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Saved poster PNG.')),
    );
  }

  // Optional: visible screenshot (kept, but not your “main” share path)
  Future<Uint8List> _capturePngFromKey(GlobalKey key) async {
    final ctx = key.currentContext;
    if (ctx == null) throw Exception('Capture target not ready');

    final boundary = ctx.findRenderObject() as RenderRepaintBoundary;

    final dpr = MediaQuery.of(context).devicePixelRatio;
    final pixelRatio = (dpr * 2).clamp(2.0, 4.0);

    final image = await boundary.toImage(pixelRatio: pixelRatio);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) throw Exception('PNG capture failed');
    return byteData.buffer.asUint8List();
  }

  Future<void> _downloadVisibleScreenshotPng() async {
    final bytes = await _capturePngFromKey(_pageCaptureKey);
    final stem = '${_safeFileStem()}_screenshot';
    await _savePngBytes(bytes, stem);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Saved screenshot PNG.')),
    );
  }

  Future<void> _shareLinkWhatsApp() async {
    final url = _buildShareUrlForGame();
    final text = Uri.encodeComponent('STS Profile – $url');
    await _launchExternalUrl('https://wa.me/?text=$text');
  }

  Future<void> _shareLinkTelegram() async {
    final url = Uri.encodeComponent(_buildShareUrlForGame());
    final text = Uri.encodeComponent('STS Profile');
    await _launchExternalUrl('https://t.me/share/url?url=$url&text=$text');
  }

  Future<void> _shareLinkX() async {
    final url = Uri.encodeComponent(_buildShareUrlForGame());
    final text = Uri.encodeComponent('STS Profile');
    await _launchExternalUrl(
        'https://twitter.com/intent/tweet?text=$text&url=$url');
  }

  Future<void> _shareLinkEmail() async {
    final subject =
        Uri.encodeComponent('STS Profile – ${widget.selectedGame.name}');
    final body = Uri.encodeComponent(
        'Here’s the STS Profile link:\n\n${_buildShareUrlForGame()}');
    await _launchExternalUrl('mailto:?subject=$subject&body=$body');
  }

  void _openShareMenu() {
    if (_analysisResult == null) return;

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final maxH = MediaQuery.of(ctx).size.height * 0.85;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxH),
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  leading: const Icon(Icons.image_outlined),
                  title: const Text('Export poster image (PNG)'),
                  subtitle: const Text('Best way to share the full visual profile'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _exportPosterPng();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.link),
                  title: const Text('Copy share link'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _copyShareLink();
                  },
                ),
                const Divider(height: 8),
                ListTile(
                  leading: const Icon(Icons.chat),
                  title: const Text('Share link via WhatsApp'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _shareLinkWhatsApp();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.send),
                  title: const Text('Share link via Telegram'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _shareLinkTelegram();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.alternate_email),
                  title: const Text('Share link via X'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _shareLinkX();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.email_outlined),
                  title: const Text('Share link via Email'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _shareLinkEmail();
                  },
                ),
                const Divider(height: 8),
                ListTile(
                  leading: const Icon(Icons.screenshot_monitor),
                  title: const Text('Save visible screenshot (PNG)'),
                  subtitle: const Text('Captures what’s currently on screen'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _downloadVisibleScreenshotPng();
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  // ==========================
  // DIALOGS + DRAWER (RESTORED)
  // ==========================

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
                      queryParameters: {'subject': 'STS Profiles – Feedback'},
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
          const DrawerHeader(
            decoration: BoxDecoration(color: Colors.black),
            child: Align(
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
                    text:
                        'If you want to inspect the code or report issues, the source is available on ',
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

          // RESTORED: “How it works” (exact same content as SearchScreen)
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

          if (kIsWeb)
            ListTile(
              leading: const Icon(Icons.install_mobile),
              title: const Text('Install on home screen'),
              onTap: () {
                Navigator.pop(context);
                _showInstallToHomeScreenDialog();
              },
            ),

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

  // ==========================
  // UI: GAME HEADER
  // ==========================

  Widget _buildGameHeaderCard() {
    final String gameName = widget.selectedGame.name;
    final String headerImageUrl = widget.selectedGame.headerImageUrl;

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

    String? releaseYear;
    if (showRelease) {
      final rd = releaseDate!.trim();
      final m = RegExp(r'(\d{4})').firstMatch(rd);
      releaseYear = m?.group(1) ?? rd;
    }

    Widget metaChip({
      required String label,
      required String value,
      required double maxWidth,
    }) {
      final text = '$label: $value';
      return ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: Text(
            text,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: Colors.blueGrey.shade800,
              height: 1.0,
            ),
          ),
        ),
      );
    }

    String subtitleLine() {
      final appIdPart = 'Steam AppID: ${widget.selectedGame.appid}';
      if (showRelease && releaseYear != null && releaseYear!.trim().isNotEmpty) {
        return '$appIdPart  •  Released: $releaseYear';
      }
      return appIdPart;
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
            _buildNiceHeaderImage(headerImageUrl),
            const SizedBox(height: kGapS),

            Text(
              gameName,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                height: 1.08,
              ),
              maxLines: null,
              overflow: TextOverflow.visible,
              softWrap: true,
            ),

            const SizedBox(height: 4),

            Text(
              subtitleLine(),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: Colors.blueGrey.shade600,
              ),
            ),

            const SizedBox(height: 10),

            if (showDev || showPub)
              LayoutBuilder(
                builder: (context, constraints) {
                  final baseMax = kIsWeb ? 320.0 : 240.0;
                  final maxW = constraints.maxWidth;
                  final chipMaxWidth = baseMax.clamp(160.0, maxW);

                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (showDev)
                        metaChip(
                          label: 'Developer',
                          value: developer!.trim(),
                          maxWidth: chipMaxWidth,
                        ),
                      if (showPub)
                        metaChip(
                          label: 'Publisher',
                          value: publisher!.trim(),
                          maxWidth: chipMaxWidth,
                        ),
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  // ---------- Compact scope row ----------
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

  // ---------- Playtime distribution card ----------
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
        _analysisResult?.reviewCountAnalyzed ?? _currentReviewCount;
    final double medianHours = distribution.medianHours;

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
                        medianHours.isNaN
                            ? 'N/A'
                            : '${value.toStringAsFixed(1)}h',
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
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                '$title\nSENTIMENT',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 6),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  verdict,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    color: color,
                    height: 1.0,
                  ),
                ),
              ),
              const SizedBox(height: 6),
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

  // ---------- Sentiment filter chips ----------
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
            reviewText.substring(0, reviewText.length.clamp(0, 10))),
        shape: const Border(),
        collapsedShape: const Border(),
        backgroundColor: Colors.white,
        collapsedBackgroundColor: Colors.white,
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
                const Text('Full Review Text:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(reviewText, style: const TextStyle(fontSize: 14)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6.0,
                  children: tags
                      .map((tag) => Chip(
                            label: Text(tag,
                                style: const TextStyle(fontSize: 10)),
                            padding: const EdgeInsets.all(2.0),
                          ))
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

  // ==========================
  // POSTER WIDGET (FULL VISUAL PROFILE)
  // ==========================

  Widget _buildPosterWidget(AnalysisResult a) {
    final t = a.thematicScores;
    final median = a.playtimeDistribution.medianHours;
    final medianStr = median.isNaN ? 'N/A' : '${median.toStringAsFixed(1)}h';

    // A clean, shareable “poster” layout (static, predictable sizing).
    return Container(
      padding: const EdgeInsets.all(18),
      color: Colors.white,
      child: DefaultTextStyle(
        style: const TextStyle(color: Colors.black87),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.selectedGame.name} – STS Profile',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            Text(
              'Steam AppID: ${widget.selectedGame.appid}',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: Colors.black54,
              ),
            ),
            const SizedBox(height: 12),

            _buildNiceHeaderImage(widget.selectedGame.headerImageUrl),

            const SizedBox(height: 14),

            Row(
              children: [
                Expanded(
                  child: _posterStatCard(
                    title: 'Analysis scope',
                    value: '${a.reviewCountAnalyzed} reviews',
                    icon: Icons.insights,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _posterStatCard(
                    title: 'Themed reviews found',
                    value: '${a.totalThemedReviews}',
                    icon: Icons.list_alt,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            _posterStatCard(
              title: 'Median total playtime',
              value: medianStr,
              icon: Icons.timer,
              big: true,
            ),

            const SizedBox(height: 12),

            Text(
              'Thematic Sentiment Breakdown',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),

            Row(
              children: [
                Expanded(child: _buildThematicScoreCard('length', t.length)),
                Expanded(child: _buildThematicScoreCard('grind', t.grind)),
                Expanded(child: _buildThematicScoreCard('value', t.value)),
              ],
            ),

            const SizedBox(height: 14),

            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(12),
                color: Colors.grey.shade50,
              ),
              child: Text(
                'Share link: ${_buildShareUrlForGame()}\n\n'
                'Note: Generated from recent Steam reviews. Automated sentiment is indicative only – not an official rating.',
                style: const TextStyle(fontSize: 12, color: Colors.black87),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _posterStatCard({
    required String title,
    required String value,
    required IconData icon,
    bool big = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(12),
        color: Colors.white,
      ),
      child: Row(
        children: [
          Icon(icon, size: big ? 22 : 18, color: Colors.blueGrey.shade700),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: big ? 12 : 11,
                    fontWeight: FontWeight.w700,
                    color: Colors.blueGrey.shade700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: big ? 20 : 16,
                    fontWeight: FontWeight.w900,
                    color: Colors.black,
                    height: 1.05,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ==========================
  // BUILD
  // ==========================

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
              icon: const Icon(Icons.ios_share),
              onPressed: _openShareMenu,
              tooltip: 'Share (poster + link)',
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
        body: _webConstrain(
          const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 20),
                Text('Analysing reviews...'),
                SizedBox(height: 8),
                Text(
                  'Please wait – there are a lot of them!',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
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
        body: _webConstrain(
          Center(
            child: Text(_error ?? 'No analysis available for this game yet.'),
          ),
        ),
      );
    }

    final analysis = _analysisResult!;

    // Hide/disable “Add 1000 more reviews” when Steam has no more to load
    final bool canAddMore = analysis.canFetchMore &&
        (analysis.steamTotalReviews == null ||
            analysis.reviewCountAnalyzed < (analysis.steamTotalReviews ?? 0));

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
      floatingActionButton: canAddMore
          ? FloatingActionButton.extended(
              onPressed: _isLoadingAnalysis
                  ? null
                  : () => _fetchAnalysisData(
                        reviewCount: nextReviewCount,
                        allowRollback: true,
                      ),
              icon: const Icon(Icons.add, size: 18, color: Colors.white),
              label: const Text(
                'Add 1000 more reviews',
                style:
                    TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
              ),
              backgroundColor: Colors.black87,
              foregroundColor: Colors.white,
              elevation: 5,
              extendedPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      body: RepaintBoundary(
        key: _pageCaptureKey,
        child: _webConstrain(
          ListView(
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
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
                reviewCountUsed: analysis.reviewCountAnalyzed,
                themedReviewsAvailable: _totalThemedReviewsAvailable,
              ),

              const SizedBox(height: 6),

              _buildPlaytimeDistributionCard(analysis.playtimeDistribution),

              const SizedBox(height: 2),

              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      'Thematic Sentiment Breakdown',
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w900),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(width: 2),
                    Transform.translate(
                      offset: const Offset(0, -12),
                      child: Tooltip(
                        message:
                            'Sentiment by theme from the most recent reviews collected for this analysis (not all reviews on Steam). Tap for details.',
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () {
                            showDialog(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title:
                                    const Text('Thematic Sentiment Breakdown'),
                                content: const Text(
                                  'This section summarises sentiment for each theme detected in the most recent reviews collected for this analysis (not all reviews on Steam).\n\n'
                                  'Sentiment is estimated automatically and may miss sarcasm, slang, jokes, or context.',
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
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 2),
                            child: Text(
                              '*',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w900,
                                color: Colors.black87,
                                height: 1,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 6),

              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Expanded(
                      child: _buildThematicScoreCard(
                          'length', analysis.thematicScores.length)),
                  Expanded(
                      child: _buildThematicScoreCard(
                          'grind', analysis.thematicScores.grind)),
                  Expanded(
                      child: _buildThematicScoreCard(
                          'value', analysis.thematicScores.value)),
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
                  'Tap a theme (Length, Grind, Value) or sentiment (Positive, Negative, Neutral) to filter the reviews below. Tap again to clear.',
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
        ),
      ),
    );
  }
}
