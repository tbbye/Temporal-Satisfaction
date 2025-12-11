import 'package:flutter/material.dart';
// Correct relative path: looks for 'screens' folder in 'lib'
import 'screens/search_screen.dart'; 

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Steam Sentiment Analyzer',
      theme: ThemeData(
        colorSchemeSeed: Colors.blue, 
        useMaterial3: true,
      ),
      home: const SearchScreen(),
    );
  }
}