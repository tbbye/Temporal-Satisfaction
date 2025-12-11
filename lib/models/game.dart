class Game {
  final String appid;
  final String name;

  Game({required this.appid, required this.name});

  factory Game.fromJson(Map<String, dynamic> json) {
    return Game(
      appid: json['appid'] as String,
      name: json['name'] as String,
    );
  }
}