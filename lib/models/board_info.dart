import 'package:json_annotation/json_annotation.dart';

part 'board_info.g.dart';

@JsonSerializable()
class BoardInfo {
  BoardInfo({
    required this.title,
    required this.content,
    required this.startDate,
    required this.endDate,
  });

  String title;
  String content;
  String startDate;
  String? endDate;

  factory BoardInfo.fromJson(Map<String, dynamic> json) =>
      _$BoardInfoFromJson(json);
  Map<String, dynamic> toJson() => _$BoardInfoToJson(this);

  static bool boardDataLoaded = false;

  static List<BoardInfo> boardList = [];

  static Future<List<BoardInfo>> load() async {
    final list = <BoardInfo>[
      BoardInfo(
        title: '欢迎使用 PixEz Archive',
        content:
            '欢迎使用 PixEz Archive 并提出建议！现在还有很多问题亟待解决 QAQ，如遇到了重大 bug，请通过 GitHub 或作者邮箱反映！'
            '<br><br><a href="https://github.com/miyasanjisaki/pixez-archive/issues">GitHub Issues</a>'
            '<br><a href="mailto:429230857@qq.com">429230857@qq.com</a>',
        startDate: '2026-08-17',
        endDate: null,
      ),
    ];
    boardList = list;
    boardDataLoaded = true;
    return list;
  }
}
