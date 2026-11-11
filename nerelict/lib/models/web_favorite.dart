/// 一条网页收藏：地址、标题、分类与收藏时间。
///
/// 顺序由 [WebFavoritesState] 中的列表顺序决定（用户可拖动调整），
/// 因此这里不按时间排序。
class WebFavorite {
  const WebFavorite({
    required this.url,
    required this.title,
    required this.addedAt,
    this.category = '',
    this.quickAccess = false,
    this.iconUrl,
  });

  final String url;
  final String title;
  final int addedAt;

  /// 分类名；空字符串表示「未分类」
  final String category;

  /// 是否放进首页「快速访问」
  final bool quickAccess;

  /// 收藏时从页面 <link rel="icon"> 自动识别到的图标地址
  final String? iconUrl;

  String get displayTitle {
    final t = title.trim();
    if (t.isNotEmpty && !t.startsWith('http')) return t;
    return host.isEmpty ? url : host;
  }

  String get host => Uri.tryParse(url)?.host ?? '';

  String get categoryLabel => category.trim().isEmpty ? '未分类' : category.trim();

  bool get isUncategorized => category.trim().isEmpty;

  WebFavorite copyWith({
    String? url,
    String? title,
    int? addedAt,
    String? category,
    bool? quickAccess,
    String? iconUrl,
  }) {
    return WebFavorite(
      url: url ?? this.url,
      title: title ?? this.title,
      addedAt: addedAt ?? this.addedAt,
      category: category ?? this.category,
      quickAccess: quickAccess ?? this.quickAccess,
      iconUrl: iconUrl ?? this.iconUrl,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'url': url,
        'title': title,
        'addedAt': addedAt,
        'category': category,
        'quickAccess': quickAccess,
        'iconUrl': iconUrl,
      };

  static WebFavorite? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final url = raw['url'];
    if (url is! String || url.isEmpty) return null;
    return WebFavorite(
      url: url,
      title: raw['title'] is String ? raw['title'] as String : '',
      addedAt: raw['addedAt'] is int ? raw['addedAt'] as int : 0,
      category: raw['category'] is String ? raw['category'] as String : '',
      quickAccess: raw['quickAccess'] == true,
      iconUrl: raw['iconUrl'] is String && (raw['iconUrl'] as String).isNotEmpty
          ? raw['iconUrl'] as String
          : null,
    );
  }
}
