import 'package:flutter/material.dart';
// Correct relative paths
import '../models/game.dart'; 
import '../models/analysis_result.dart';
import '../services/api_service.dart';
import 'analysis_screen.dart'; 

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final ApiService _apiService = ApiService();
  List<Game> _searchResults = [];
  bool _isSearching = false;
  String? _analysisStatus; 

  void _performSearch(String query) async {
    if (query.length < 3) {
      setState(() {
        _searchResults = [];
      });
      return;
    }
    
    setState(() {
      _isSearching = true;
    });

    final List<Game> results = await _apiService.searchGames(query);
    
    setState(() {
      _searchResults = results;
      _isSearching = false;
    });
  }

  void _onGameSelected(Game selectedGame) async {
    setState(() {
      _analysisStatus = "Analyzing '${selectedGame.name}'... This may take up to 40 seconds.";
    });

    try {
      final AnalysisResult result = await _apiService.analyzeReviews(selectedGame.appid);
      
      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => AnalysisScreen(
              gameName: selectedGame.name,
              result: result,
            ),
          ),
        );
      }
    } catch (e) {
      setState(() {
        _analysisStatus = "Error analyzing reviews: $e";
      });
    } finally {
      setState(() {
        _analysisStatus = null; 
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Steam Temporal Satisfaction'),
        backgroundColor: Theme.of(context).colorScheme.primary, 
      ),
      body: Column(
        children: <Widget>[
          // --- Search Input ---
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextField(
              decoration: const InputDecoration(
                labelText: 'Enter Game Name (e.g., Portal, Elden)',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: _performSearch, 
            ),
          ),
          
          // --- Analysis Status Overlay ---
          if (_analysisStatus != null) 
            ListTile(
              leading: const CircularProgressIndicator(),
              title: Text(_analysisStatus!),
            ),

          // --- Search Results List ---
          Expanded(
            child: _isSearching && _searchResults.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: _searchResults.length,
                    itemBuilder: (context, index) {
                      final game = _searchResults[index];
                      return ListTile(
                        title: Text(game.name),
                        subtitle: Text('App ID: ${game.appid}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _onGameSelected(game),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}