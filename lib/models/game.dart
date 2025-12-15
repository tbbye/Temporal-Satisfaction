class Game {
  final String appid;
  final String name;
  final String headerImageUrl;

  // NEW
  final String developer;
  final String publisher;
  final String? releaseDate; // or releaseYear if you prefer

  Game({
    required this.appid,
    required this.name,
    required this.headerImageUrl,
    required this.developer,
    required this.publisher,
    required this.releaseDate,
  });

  factory Game.fromJson(Map<String, dynamic> json) {
    return Game(
      appid: json['appid']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      headerImageUrl: json['header_image_url']?.toString() ?? '',
      developer: json['developer']?.toString() ?? 'N/A',
      publisher: json['publisher']?.toString() ?? 'N/A',
      releaseDate: json['release_date'] as String?, // <-- backend field
    );
  }
}
