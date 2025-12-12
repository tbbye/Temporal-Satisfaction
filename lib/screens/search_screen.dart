// lib/screens/search_screen.dart

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/gestures.dart';

import '../models/game.dart';
import '../services/api_service.dart' as backend;
import 'analysis_screen.dart' as screens;

// Your real Buy Me a Coffee URL
const String _buyMeACoffeeUrl = 'https://www.buymeacoffee.com/tbbye';

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

  // ---------- Helpers for Drawer ----------

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

  /// Feedback dialog with clickable "here" email link
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

  Future<void> _launchBuyMeACoffee() async {
    final uri = Uri.parse(_buyMeACoffeeUrl);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open Buy Me a Coffee link.')),
      );
    }
  }

  Drawer _buildAppDrawer(BuildContext context) {
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
            leading: const Icon(Icons.policy),
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
            leading: const Icon(Icons.favorite_outline),
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

          // Buy Me a Coffee
          ListTile(
            leading: const Icon(Icons.local_cafe_outlined),
            title: const Text('Buy me a coffee'),
            onTap: () {
              Navigator.pop(context);
              _launchBuyMeACoffee();
            },
          ),
        ],
      ),
    );
  }

  // ---------- Search logic ----------

  Future<void> _performSearch(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _searchResults.clear();
      });
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final results = await _apiService.searchGames(query);

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
      });
    } catch (e) {
      // ignore: avoid_print
      print('Search Error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to search games.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Steam Game Analyzer'),
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
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                labelText: 'Search Game Name',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () => _performSearch(_searchController.text),
                ),
                border: const OutlineInputBorder(),
              ),
              onSubmitted: _performSearch,
            ),
            const SizedBox(height: 20),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _searchResults.isEmpty
                      ? const Center(
                          child: Text('No results yet. Try a search.'),
                        )
                      : ListView.builder(
                          itemCount: _searchResults.length,
                          itemBuilder: (context, index) {
                            final game = _searchResults[index];
                            return ListTile(
                              leading: SizedBox(
                                width: 60,
                                child: Image.network(
                                  game.headerImageUrl,
                                  fit: BoxFit.cover,
                                  errorBuilder:
                                      (context, error, stackTrace) =>
                                          const Icon(
                                    Icons.videogame_asset,
                                    size: 40,
                                  ),
                                ),
                              ),
                              title: Text(game.name),
                              subtitle: Text('App ID: ${game.appid}'),
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) =>
                                        screens.AnalysisScreen(
                                      selectedGame: game,
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
