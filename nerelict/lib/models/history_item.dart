/// 一条浏览历史：页面地址、标题与访问时间。
class HistoryItem {
  const HistoryItem({
    required this.url,
    required this.title,
    required this.visitedAt,
  });

  final String url;
  final String title;
  final DateTime visitedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'url': url,
        'title': title,
        't': visitedAt.millisecondsSinceEpoch,
      };

  static HistoryItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final url = raw['url'];
    final t = raw['t'];
    if (url is! String || url.isEmpty || t is! int) return null;
    return HistoryItem(
      url: url,
      title: raw['title'] is String ? raw['title'] as String : '',
      visitedAt: DateTime.fromMillisecondsSinceEpoch(t),
    );
  }

  /// 列表里展示用的标题：优先网页标题，其次域名。
  String get displayTitle {
    final t = title.trim();
    if (t.isNotEmpty && !t.startsWith('http')) return t;
    return Uri.tryParse(url)?.host ?? url;
  }

  String get displayHost => Uri.tryParse(url)?.host ?? '';
}
