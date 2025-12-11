import 'package:flutter/material.dart';
// Correct relative path: up one directory (to lib), then into 'models'
import '../models/analysis_result.dart'; 

class AnalysisScreen extends StatelessWidget {
  final String gameName;
  final AnalysisResult result;

  const AnalysisScreen({
    super.key,
    required this.gameName,
    required this.result,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Results for $gameName'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Game Time Sentiment Analysis',
              style: Theme.of(context).textTheme.headlineMedium,
              textAlign: TextAlign.center,
            ),
            const Divider(height: 40),
            
            _buildResultCard(
              'Time-Centric Reviews Found',
              '${result.timeCentricReviewsFound}',
              Icons.timer,
              Colors.blue,
            ),
            _buildResultCard(
              'Total Reviews Collected',
              '${result.totalReviewsCollected}',
              Icons.list_alt,
              Colors.grey,
            ),
            const Divider(height: 40),

            _buildResultCard(
              'WELL SPENT Time Sentiment',
              '${result.positiveSentimentPercent.toStringAsFixed(2)}%',
              Icons.thumb_up,
              Colors.green,
            ),
            _buildResultCard(
              'WASTED Time Sentiment',
              '${result.negativeSentimentPercent.toStringAsFixed(2)}%',
              Icons.thumb_down,
              Colors.red,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultCard(String title, String value, IconData icon, Color color) {
    return Card(
      elevation: 3,
      margin: const EdgeInsets.only(bottom: 15),
      child: ListTile(
        leading: Icon(icon, color: color, size: 30),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        trailing: Text(
          value,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color),
        ),
      ),
    );
  }
}