class Game {
  final String appid;
  final String name;
  // NEW: Field for the image URL
  final String headerImageUrl; 

  Game({
    required this.appid, 
    required this.name,
    required this.headerImageUrl, // NEW
  });

  factory Game.fromJson(Map<String, dynamic> json) {
    return Game(
      appid: json['appid'] as String,
      name: json['name'] as String,
      headerImageUrl: json['header_image_url'] as String, // NEW: Deserialize the image URL
    );
  }
}