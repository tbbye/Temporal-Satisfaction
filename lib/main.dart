import 'package:flutter/material.dart';
// Note: This import is necessary for the next step, the API call.
import 'package:http/http.dart' as http; 
import 'dart:convert'; // For working with JSON data

// 1. The Main Entry Point
void main() {
  runApp(const MyApp());
}

// StatelessWidget: Defines the app's basic style and identity (no changing state)
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Steam Sentiment Analyzer',
      theme: ThemeData(
        // Set a color scheme for the app's design
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      // Set the home page to our main design widget
      home: const SentimentPage(),
    );
  }
}

// StatefulWidget: This is the core design widget that will change its appearance
// based on user actions (like button clicks) and API results.
class SentimentPage extends StatefulWidget {
  const SentimentPage({super.key});

  @override
  // Creates the mutable state for the UI
  State<SentimentPage> createState() => _SentimentPageState();
}

// The State class where the UI is actually defined and built.
class _SentimentPageState extends State<SentimentPage> {
  // --- UI STATE VARIABLES ---
  final TextEditingController _appIdController = TextEditingController();
  String _resultText = "Enter a Steam App ID to analyze community sentiment.";
  bool _isLoading = false; // Controls if the button shows a spinner

  // --- API ENDPOINT ---
  // **CRITICAL:** Replace the URL below with YOUR actual Render URL!
  final String _apiUrl = "https://temporal-satisfaction.onrender.com/analyze"; 
  
  // --- DESIGN: The API Call Logic (Placeholder) ---
  void _analyzeSentiment() async {
    // 1. Validate Input
    final appId = _appIdController.text;
    if (appId.isEmpty) {
      setState(() {
        _resultText = "Please enter a valid App ID.";
      });
      return;
    }

    // 2. Start Loading State and Clear Results
    setState(() {
      _isLoading = true;
      _resultText = "Analyzing reviews for App ID $appId... (Collecting up to 1000 reviews)";
    });

    // 3. Make the API Request
    try {
      final response = await http.post(
        Uri.parse(_apiUrl),
        headers: <String, String>{
          'Content-Type': 'application/json; charset=UTF-8',
        },
        body: jsonEncode(<String, String>{
          'app_id': appId, // Send the user's input to the API
        }),
      );

      // 4. Handle Response
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        
        // Use the returned percentage data to update the UI
        setState(() {
          _isLoading = false;
          _resultText = "✅ Success!\n\n"
              "Time-Centric Reviews Found: ${data['time_centric_reviews_found']}\n"
              "Community Sentiment:\n"
              "WELL SPENT: ${data['positive_sentiment_percent']}% \n"
              "WASTED TIME: ${data['negative_sentiment_percent']}%";
        });
      } else {
        // Handle API errors (e.g., App ID not found)
        setState(() {
          _isLoading = false;
          _resultText = "❌ Error: API failed with status ${response.statusCode}. Check your Render logs.";
        });
      }
    } catch (e) {
      // Handle network errors (e.g., no internet, wrong URL)
      setState(() {
        _isLoading = false;
        _resultText = "❌ Network Error: Could not reach the server. Check the URL.";
      });
    }
  }

  // --- DESIGN: The Widget Build Function ---
  @override
  Widget build(BuildContext context) {
    // Scaffold is the primary structural widget for a screen (like a blank canvas)
    return Scaffold(
      appBar: AppBar(
        title: const Text('Steam Temporal Satisfaction'),
        backgroundColor: Theme.of(context).primaryColor,
      ),
      // Padding adds space around the edges
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column( // Column arranges widgets vertically
          crossAxisAlignment: CrossAxisAlignment.stretch, // Makes items full width
          children: <Widget>[
            // 1. Input Field (The design for the Steam App ID)
            TextField(
              controller: _appIdController,
              keyboardType: TextInputType.number, // Shows number keyboard on phone
              decoration: const InputDecoration(
                labelText: 'Steam App ID (e.g., 440 or 1245620)',
                hintText: 'Enter a numeric App ID',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 25), // Space divider

            // 2. The Button (The interactive design element)
            ElevatedButton(
              onPressed: _isLoading ? null : _analyzeSentiment, // Disable when loading
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 50), // Set minimum size
              ),
              child: _isLoading 
                ? const SizedBox(
                    height: 20, width: 20, 
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white), // Design for loading spinner
                  )
                : const Text( // Design for button text
                    'Analyze Community Sentiment', 
                    style: TextStyle(fontSize: 18),
                  ),
            ),

            const SizedBox(height: 50), // Space divider

            // 3. Result Display Area (The design for showing results)
            Card(
              elevation: 4, // Design for a slight shadow
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Text(
                  _resultText,
                  textAlign: TextAlign.left,
                  style: const TextStyle(
                    fontSize: 16,
                    fontFamily: 'monospace', // Design for a monospace font for data clarity
                    height: 1.5,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}