// lib/screens/search_screen.dart

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../models/game.dart';
import '../services/api_service.dart' as backend;
import 'analysis_screen.dart'
    show AnalysisScreen, kGapS, kGapM, kElevLow, kElevMed;

// Your real Buy Me a Coffee URL
const String _buyMeACoffeeUrl = 'https://www.buymeacoffee.com/tbbye';

// Paper URL
const String _paperUrl = 'https://dl.acm.org/doi/10.1145/3764687.3764693';

// OPTIONAL: your GitHub repo (add your real link here)
const String _githubUrl = 'https://github.com/tbbye/Temporal-Satisfaction';

// ---------- TYPOGRAPHY (separated so you can tweak individually) ----------

const FontWeight kTitleWeight = FontWeight.w900;

// Hero
const double kHeroTitleSize = 30; // "Search Steam"
const double kHeroSubtitleSize = 18; // "Generate STS* Profiles"

// Featured section header
const double kFeaturedSectionTitleSize = 22; // "Featured games"

// Featured game title (inside carousel)
const double kFeaturedGameNameSize = 20;

// ---------- Layout tuning ----------

// Match AnalysisScreen web layout tuning
const double kWebMaxWidth = 860;

/// Featured game pool (name-only). We enrich by searching Steam for metadata.
const List<String> kFeaturedGameNames = [
  'Blue Prince',
  'Inscryption',
  'System Shock',
  'Clair Obscur: Expedition 33',
  'Hollow Knight: Silksong',
  'Untitled Goose Game',
  "Baldur's Gate 3",
  'Wayward Strand',
  'Destiny 2',
];

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  final List<Game> _searchResults = [];
  final backend.ApiService _apiService = backend.ApiService();

  bool _isLoading = false;
  String? _error;

  // Only show "No matches" after a real search has happened
  bool _hasSearched = false;

  // Featured carousel state (on-demand)
  late final PageController _featuredController;
  int _featuredIndex = 0;

  bool _featuredLoadingStarted = false;
  List<Game> _featuredGames = [];

  final Set<int> _featuredLoading = <int>{};
  final Set<int> _featuredLoaded = <int>{};

  // --- Featured carousel auto-advance ---
  Timer? _featuredAutoTimer;
  DateTime _lastFeaturedUserInteraction = DateTime.now();
  bool _featuredUserScrolling = false;
  bool _autoAdvancingFeatured = false;

  // --- Deep link (web share URLs) ---
  bool _handledIncomingLink = false;

  // Tweak these if you want
  static const Duration _autoAdvanceEvery = Duration(seconds: 5);
  static const Duration _resumeAfterIdle = Duration(seconds: 7);

  @override
  void initState() {
    super.initState();

    _featuredController = PageController(viewportFraction: 1.0);
    _initFeaturedCarouselOnDemand();

    _startFeaturedAutoAdvance();

    // ✅ Handle shared URLs like:
    // https://yoursite/#/ OR https://yoursite/?appid=570&name=Dota%202
    // We only do this on web, and only once.
    if (kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleIncomingShareLink();
      });
    }

    _searchController.addListener(() {
      if (!mounted) return;
      setState(() {
        // typing should not set _hasSearched
      });
    });
  }

  @override
  void dispose() {
    _stopFeaturedAutoAdvance();
    _featuredController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  // ---------- Web constraint (matches AnalysisScreen) ----------

  Widget _webConstrain(Widget child) {
    if (!kIsWeb) return child;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kWebMaxWidth),
        child: child,
      ),
    );
  }

  // ---------- Shared “nice banner” image treatment (matches AnalysisScreen vibe) ----------

  Widget _buildNiceHeaderImage(String url) {
    if (url.trim().isEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AspectRatio(
          aspectRatio: 460 / 215,
          child: Container(
            color: Colors.grey.shade200,
            child: const Center(
              child:
                  Icon(Icons.videogame_asset, size: 30, color: Colors.black54),
            ),
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: AspectRatio(
        aspectRatio: 460 / 215,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Background fill
            Image.network(
              url,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.high,
              errorBuilder: (context, error, stackTrace) =>
                  Container(color: Colors.grey.shade200),
            ),

            // Blur + subtle tint
            BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(color: Colors.black.withOpacity(0.12)),
            ),

            // Foreground contain (full banner visible)
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
          ],
        ),
      ),
    );
  }

  // ---------- Deep link handling (web share URLs) ----------

  String _steamHeaderUrlFromAppId(String appId) =>
      'https://cdn.akamai.steamstatic.com/steam/apps/$appId/header.jpg';

  Future<void> _handleIncomingShareLink() async {
    if (!mounted) return;
    if (_handledIncomingLink) return;
    _handledIncomingLink = true;

    final uri = Uri.base;
    final appid = uri.queryParameters['appid'];
    if (appid == null || appid.trim().isEmpty) return;

    final name = (uri.queryParameters['name'] ?? 'Steam App $appid').trim();

    // Build a minimal Game object so analysis can run.
    // (Developer/publisher/release date will be N/A unless later enriched.)
    final game = Game(
      appid: appid.trim(),
      name: name.isEmpty ? 'Steam App $appid' : name,
      headerImageUrl: _steamHeaderUrlFromAppId(appid.trim()),
      developer: 'N/A',
      publisher: 'N/A',
      releaseDate: 'N/A',
    );

    // If the user is actively typing a search, don’t rudely yank them away.
    if (_searchController.text.trim().isNotEmpty) {
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AnalysisScreen(selectedGame: game),
      ),
    );
  }

  // ---------- Featured game helpers ----------

  bool _isMissingMeta(String? v) {
    final t = v?.trim() ?? '';
    return t.isEmpty || t.toLowerCase() == 'n/a';
  }

  String _safeTrim(String? v) => v?.trim() ?? '';

  Future<Game?> _enrichViaSteamStoreApi(String appId, Game base) async {
    // Steam Store API is often blocked by CORS on Flutter Web.
    // We still try – and fail gracefully.
    if (appId.trim().isEmpty) return base;

    final uri = Uri.parse(
      'https://store.steampowered.com/api/appdetails?appids=$appId&l=english',
    );

    try {
      final resp = await http.get(uri);
      if (resp.statusCode != 200) return base;

      final decoded = jsonDecode(resp.body);
      final entry = decoded[appId];
      if (entry == null || entry['success'] != true) return base;

      final data = entry['data'] as Map<String, dynamic>?;
      if (data == null) return base;

      final devs = (data['developers'] is List)
          ? (data['developers'] as List).whereType<String>().toList()
          : <String>[];

      final pubs = (data['publishers'] is List)
          ? (data['publishers'] as List).whereType<String>().toList()
          : <String>[];

      final releaseDateObj = data['release_date'] is Map<String, dynamic>
          ? data['release_date'] as Map<String, dynamic>
          : null;

      final releaseDate = (releaseDateObj?['date'] is String)
          ? releaseDateObj!['date'] as String
          : '';

      final headerImage = (data['header_image'] is String)
          ? data['header_image'] as String
          : base.headerImageUrl;

      return Game(
        appid: base.appid,
        name: base.name,
        headerImageUrl: headerImage.isNotEmpty
            ? headerImage
            : _steamHeaderUrlFromAppId(base.appid),
        developer: devs.isNotEmpty ? devs.join(', ') : base.developer,
        publisher: pubs.isNotEmpty ? pubs.join(', ') : base.publisher,
        releaseDate: releaseDate.isNotEmpty ? releaseDate : base.releaseDate,
      );
    } catch (e) {
      return base;
    }
  }

  Future<Game?> _resolveFeaturedGameByName(String name) async {
    final results = await _apiService.searchGames(name);
    if (results.isEmpty) return null;

    Game? match;
    final q = name.trim().toLowerCase();

    for (final g in results) {
      if (g.name.trim().toLowerCase() == q) {
        match = g;
        break;
      }
    }
    match ??= results.first;

    final headerUrl = (match.headerImageUrl.isNotEmpty)
        ? match.headerImageUrl
        : _steamHeaderUrlFromAppId(match.appid);

    var enriched = Game(
      appid: match.appid,
      name: match.name,
      headerImageUrl: headerUrl,
      developer: match.developer,
      publisher: match.publisher,
      releaseDate: match.releaseDate,
    );

    final needsMore = (_isMissingMeta(enriched.developer) ||
            _isMissingMeta(enriched.publisher) ||
            _isMissingMeta(enriched.releaseDate)) &&
        enriched.appid != '0';

    if (needsMore) {
      enriched = await _enrichViaSteamStoreApi(enriched.appid, enriched) ??
          enriched;
    }

    return enriched;
  }

  Future<void> _initFeaturedCarouselOnDemand() async {
    if (_featuredLoadingStarted) return;
    _featuredLoadingStarted = true;

    final placeholders = kFeaturedGameNames
        .map(
          (n) => Game(
            appid: '0',
            name: n,
            headerImageUrl: '',
            developer: 'N/A',
            publisher: 'N/A',
            releaseDate: 'N/A',
          ),
        )
        .toList();

    setState(() {
      _featuredGames = placeholders;
      _featuredIndex = 0;
    });

    _ensureFeaturedLoaded(0);
    _ensureFeaturedLoaded(1);
  }

  Future<void> _ensureFeaturedLoaded(int index) async {
    if (!mounted) return;
    if (index < 0 || index >= _featuredGames.length) return;

    if (_featuredLoaded.contains(index) || _featuredLoading.contains(index)) {
      return;
    }
    _featuredLoading.add(index);

    final name = kFeaturedGameNames[index];

    try {
      final resolved = await _resolveFeaturedGameByName(name);
      if (!mounted) return;

      if (resolved != null) {
        setState(() {
          final next = List<Game>.from(_featuredGames);
          next[index] = resolved;
          _featuredGames = next;
          _featuredLoaded.add(index);
        });
      }
    } catch (e) {
      // keep placeholder
    } finally {
      _featuredLoading.remove(index);
    }
  }

  void _goToFeatured(int index) {
    if (index < 0 || index >= _featuredGames.length) return;
    _featuredController.animateToPage(
      index,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  Future<void> _openFeaturedProfileEvenIfLoading() async {
    if (_featuredGames.isEmpty) return;

    final idx = _featuredIndex;
    final current = _featuredGames[idx];

    if (current.appid != '0') {
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => AnalysisScreen(selectedGame: current),
        ),
      );
      return;
    }

    final name = kFeaturedGameNames[idx];

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Loading featured game…')),
    );

    try {
      final resolved = await _resolveFeaturedGameByName(name);
      if (!mounted) return;

      if (resolved == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not load this featured game.')),
        );
        return;
      }

      setState(() {
        final next = List<Game>.from(_featuredGames);
        next[idx] = resolved;
        _featuredGames = next;
        _featuredLoaded.add(idx);
      });

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => AnalysisScreen(selectedGame: resolved),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not load this featured game.')),
      );
    }
  }

  // ---------- Auto-advance controls ----------

  void _markFeaturedUserInteraction() {
    _lastFeaturedUserInteraction = DateTime.now();
  }

  void _startFeaturedAutoAdvance() {
    _featuredAutoTimer?.cancel();
    _featuredAutoTimer = Timer.periodic(_autoAdvanceEvery, (timer) {
      if (!mounted) return;

      // Only run when Featured is visible
      if (_searchController.text.trim().isNotEmpty) return;
      if (_featuredGames.isEmpty) return;
      if (_featuredUserScrolling) return;

      final idleFor = DateTime.now().difference(_lastFeaturedUserInteraction);
      if (idleFor < _resumeAfterIdle) return;

      final next = (_featuredIndex + 1) % _featuredGames.length;

      _autoAdvancingFeatured = true;
      _goToFeatured(next);

      Future.delayed(const Duration(milliseconds: 350), () {
        if (!mounted) return;
        _autoAdvancingFeatured = false;
      });
    });
  }

  void _stopFeaturedAutoAdvance() {
    _featuredAutoTimer?.cancel();
    _featuredAutoTimer = null;
  }

  // ---------- Helpers for Dialogs ----------

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

  void _showStsTooltipDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('About STS'),
        content: Text.rich(
          TextSpan(
            style: Theme.of(ctx).textTheme.bodyMedium,
            children: [
              const TextSpan(
                text:
                    'STS stands for Steam Temporal Satisfaction.\n\nTemporal satisfaction was a finding from the research that led to this app. You can read about it ',
              ),
              TextSpan(
                text: 'here',
                style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                      color: Colors.blue,
                      decoration: TextDecoration.underline,
                      fontWeight: FontWeight.w700,
                    ),
                recognizer: TapGestureRecognizer()
                  ..onTap = () async {
                    final uri = Uri.parse(_paperUrl);
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
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

  // ✅ Install to Home Screen (browser-first instructions, Chrome menu gesture)
  void _showInstallToHomeScreenDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Install on home screen'),
        content: const Text(
          'Android (Chrome):\n'
          '1) Tap the ⋮ (three-dot) menu (top-right)\n'
          '2) Tap “Install app” or “Add to Home screen”\n\n'
          'Desktop (Chrome / Edge):\n'
          '1) Look for the install icon in the address bar (usually a monitor with a down arrow)\n'
          '2) Or open the ⋮ menu and choose “Install”\n\n'
          'iPhone/iPad (Safari):\n'
          '1) Tap the Share button\n'
          '2) Tap “Add to Home Screen”\n\n'
          'If you don’t see install options, the browser may not consider the site installable yet (often HTTPS, a valid manifest, and a service worker are required).',
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

  Future<void> _launchBuyMeACoffee() async {
    final uri = Uri.parse(_buyMeACoffeeUrl);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open Buy Me a Coffee link.')),
      );
    }
  }

  Future<void> _launchGithub() async {
    final uri = Uri.parse(_githubUrl);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open GitHub link.')),
      );
    }
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
                        'The app relies on Valve’s public Steam Web API. Content may change or be removed at any time.This project is not affiliated with, sponsored by, or endorsed by Valve Corporation or Steam.\n\n',
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
    _launchBuyMeACoffee();
  },
),

// (no second divider + no duplicate tiles)
],
      ),
    );
  }

  // ---------- Search logic ----------

  Future<void> _performSearch(String query) async {
    final trimmed = query.trim();

    if (trimmed.isEmpty) {
      setState(() {
        _searchResults.clear();
        _error = null;
        _hasSearched = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
      _hasSearched = true;
    });

    try {
      final results = await _apiService.searchGames(trimmed);

      final filtered = results.where((game) {
        final name = game.name.toLowerCase();
        return !name.contains('expansion') &&
            !name.contains('bundle') &&
            !name.contains('soundtrack');
      }).toList();

      if (!mounted) return;
      setState(() {
        _searchResults
          ..clear()
          ..addAll(filtered);
        _error = null;
      });
    } catch (e) {
      // ignore: avoid_print
      print('Search Error: $e');
      if (!mounted) return;
      setState(() {
        _error = 'Failed to search Steam.\nPlease try again.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to search games.')),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  // ---------- UI bits ----------

  Widget _buildHeroCard() {
    return Card(
      elevation: kElevMed,
      color: Colors.white,
      surfaceTintColor: Colors.white,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Search Steam',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: kHeroTitleSize,
                      fontWeight: kTitleWeight,
                      color: Colors.black,
                      height: 1.05,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text.rich(
                    TextSpan(
                      style: const TextStyle(
                        fontSize: kHeroSubtitleSize,
                        fontWeight: kTitleWeight,
                        color: Colors.black,
                        height: 1.05,
                      ),
                      children: [
                        const TextSpan(text: 'Generate '),
                        const TextSpan(text: 'STS'),
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: Transform.translate(
                            offset: const Offset(0, -2),
                            child: Tooltip(
                              message:
                                  'STS = Steam Temporal Satisfaction. Tap for details.',
                              child: InkWell(
                                onTap: _showStsTooltipDialog,
                                borderRadius: BorderRadius.circular(10),
                                child: const Padding(
                                  padding:
                                      EdgeInsets.only(left: 2, right: 2),
                                  child: Text(
                                    '*',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w900,
                                      color: Colors.black,
                                      height: 1.0,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const TextSpan(text: 'Profiles'),
                      ],
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'See how players talk about time in play across Length, Grind, and Value.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.black87),
            ),
            const SizedBox(height: 10),
            const Text(
              '1) Search a game   2) Open its STS Profile   3) Filter, export, and share',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                fontStyle: FontStyle.normal,
                color: Colors.black54,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    textInputAction: TextInputAction.search,
                    onSubmitted: _performSearch,
                    decoration: InputDecoration(
                      hintText: 'Type a game name…',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide:
                            const BorderSide(color: Colors.black, width: 2),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: kGapS),
                ElevatedButton.icon(
                  onPressed: _isLoading
                      ? null
                      : () => _performSearch(_searchController.text),
                  icon: const Icon(Icons.search, size: 16),
                  label: const Text('Search'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    minimumSize: const Size(0, 0),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Tip: try the exact game name for better results.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: Colors.black54,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFeaturedCarouselCard() {
    if (_featuredGames.isEmpty) return const SizedBox.shrink();

    final current = _featuredGames[_featuredIndex];
    final bool isPlaceholder = current.appid == '0';
    final bool isCurrentLoading = _featuredLoading.contains(_featuredIndex);

    Widget buildFeaturedPage(Game g, int index) {
      final bool pagePlaceholder = g.appid == '0';
      final bool pageLoading = _featuredLoading.contains(index);

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (pagePlaceholder || _safeTrim(g.headerImageUrl).isEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: AspectRatio(
                aspectRatio: 460 / 215,
                child: Container(
                  color: Colors.grey.shade200,
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          pageLoading ? Colors.black : Colors.black54,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            )
          else
            _buildNiceHeaderImage(g.headerImageUrl),
          const SizedBox(height: 4),

          // Featured game name
          Text(
            g.name,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textHeightBehavior: const TextHeightBehavior(
              applyHeightToFirstAscent: false,
              applyHeightToLastDescent: false,
            ),
            style: const TextStyle(
              fontSize: kFeaturedGameNameSize,
              fontWeight: FontWeight.w900,
              color: Colors.black,
              height: 1.05,
            ),
          ),

          const SizedBox(height: 2),

          // AppID line
          Text(
            pagePlaceholder ? 'Loading…' : 'Steam AppID: ${g.appid}',
            textHeightBehavior: const TextHeightBehavior(
              applyHeightToFirstAscent: false,
              applyHeightToLastDescent: false,
            ),
            style: const TextStyle(
              fontSize: 11,
              color: Colors.black54,
              fontWeight: FontWeight.w600,
              height: 1.05,
            ),
          ),
        ],
      );
    }

    return Card(
      elevation: kElevMed,
      color: Colors.white,
      surfaceTintColor: Colors.white,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Featured games',
              style: TextStyle(
                fontSize: kFeaturedSectionTitleSize,
                fontWeight: kTitleWeight,
                color: Colors.black,
              ),
            ),
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, constraints) {
                final bannerH = constraints.maxWidth * (215 / 460);
                const metaH = 58.0;
                final totalH = bannerH + metaH;

                return SizedBox(
                  height: totalH,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n is ScrollStartNotification) {
                        _featuredUserScrolling = true;
                        if (!_autoAdvancingFeatured) {
                          _markFeaturedUserInteraction();
                        }
                      } else if (n is ScrollEndNotification) {
                        _featuredUserScrolling = false;
                        if (!_autoAdvancingFeatured) {
                          _markFeaturedUserInteraction();
                        }
                      }
                      return false;
                    },
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanDown: (_) {
                        _featuredUserScrolling = true;
                        _markFeaturedUserInteraction();
                      },
                      onPanCancel: () {
                        _featuredUserScrolling = false;
                        _markFeaturedUserInteraction();
                      },
                      onPanEnd: (_) {
                        _featuredUserScrolling = false;
                        _markFeaturedUserInteraction();
                      },
                      child: PageView.builder(
                        controller: _featuredController,
                        itemCount: _featuredGames.length,
                        onPageChanged: (i) {
                          if (!mounted) return;

                          setState(() => _featuredIndex = i);

                          if (!_autoAdvancingFeatured) {
                            _markFeaturedUserInteraction();
                          }

                          _ensureFeaturedLoaded(i);
                          _ensureFeaturedLoaded(i + 1);
                          _ensureFeaturedLoaded(i - 1);
                        },
                        itemBuilder: (context, index) =>
                            buildFeaturedPage(_featuredGames[index], index),
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_featuredGames.length, (i) {
                final bool active = i == _featuredIndex;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  height: 6,
                  width: active ? 16 : 6,
                  decoration: BoxDecoration(
                    color: active ? Colors.black : Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(99),
                  ),
                );
              }),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton(
                  onPressed: _featuredIndex > 0
                      ? () {
                          _markFeaturedUserInteraction();
                          _goToFeatured(_featuredIndex - 1);
                        }
                      : null,
                  child: const Icon(Icons.chevron_left),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _featuredIndex < _featuredGames.length - 1
                      ? () {
                          _markFeaturedUserInteraction();
                          _goToFeatured(_featuredIndex + 1);
                        }
                      : null,
                  child: const Icon(Icons.chevron_right),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _openFeaturedProfileEvenIfLoading,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 12),
                      minimumSize: const Size(0, 0),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(width: 8),
                        const Text('Open STS Profile'),
                        if (isPlaceholder || isCurrentLoading) ...[
                          const SizedBox(width: 10),
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.white),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 18),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search, size: 40, color: Colors.black54),
            SizedBox(height: 12),
            Text(
              'Search to see matches',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
            ),
            SizedBox(height: 6),
            Text(
              'If you haven’t used the app in a while, the first search can take a little longer as the server restarts – this is normal.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoResultsState() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 18),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.sentiment_dissatisfied, size: 40, color: Colors.black54),
            SizedBox(height: 12),
            Text(
              'No matches found',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
            ),
            SizedBox(height: 6),
            Text(
              'Try a different spelling, fewer words, or the exact Steam title.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultCard(Game game) {
    return Card(
      elevation: kElevLow,
      color: Colors.white,
      surfaceTintColor: Colors.white,
      margin: const EdgeInsets.only(bottom: kGapS),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => AnalysisScreen(selectedGame: game),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  width: 76,
                  height: 40,
                  color: Colors.grey.shade100,
                  child: Image.network(
                    game.headerImageUrl,
                    fit: BoxFit.cover,
                    loadingBuilder: (context, child, loadingProgress) {
                      if (loadingProgress == null) return child;
                      return Container(
                        color: Colors.grey.shade200,
                        child: const Center(
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      );
                    },
                    errorBuilder: (context, error, stackTrace) =>
                        const Center(
                            child: Icon(Icons.videogame_asset, size: 22)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      game.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Steam AppID: ${game.appid}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.black54,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, color: Colors.black54),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String query = _searchController.text.trim();
    final bool showFeatured = query.isEmpty;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text(
          'STS Profiles',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        actions: [
          Builder(
            builder: (ctx) => IconButton(
              icon: const Icon(Icons.menu),
              tooltip: 'Menu',
              onPressed: () => Scaffold.of(ctx).openEndDrawer(),
            ),
          ),
        ],
      ),
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
      body: SafeArea(
        child: _webConstrain(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: CustomScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                SliverToBoxAdapter(child: _buildHeroCard()),
                const SliverToBoxAdapter(child: SizedBox(height: kGapS)),
                if (showFeatured) ...[
                  SliverToBoxAdapter(child: _buildFeaturedCarouselCard()),
                  const SliverToBoxAdapter(child: SizedBox(height: kGapM)),
                ],
                if (_error != null)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: kGapS),
                      child: Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.red,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                if (_isLoading)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text(
                            'Finding your game… please wait',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w800),
                          ),
                          SizedBox(height: 6),
                          Text(
                            'If you haven’t used the app in a while, the server may be waking up.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 12, color: Colors.black54),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (_searchResults.isEmpty && query.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _buildEmptyState(),
                  )
                else if (_searchResults.isEmpty &&
                    query.isNotEmpty &&
                    _hasSearched)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _buildNoResultsState(),
                  )
                else if (_searchResults.isEmpty &&
                    query.isNotEmpty &&
                    !_hasSearched)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _buildEmptyState(),
                  )
                else
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => _buildResultCard(_searchResults[index]),
                      childCount: _searchResults.length,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
