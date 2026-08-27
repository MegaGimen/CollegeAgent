class UserModel {
  final String userId;
  final String username;

  const UserModel({
    required this.userId,
    required this.username,
  });

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      userId: json['userId'] as String,
      username: json['username'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'username': username,
  };
}
