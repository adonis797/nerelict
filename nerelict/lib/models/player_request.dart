/// 播放器三态，共用同一个播放内核与同一个浮层实例。
enum PlayerMode {
  /// 可拖动的浮层（默认，保持原有布局）
  panel,

  /// 全屏，横屏显示
  fullscreen,

  /// 迷你小窗，仅显示画面与展开/关闭
  mini,
}

/// MA8N的一次播放请求。
///
/// 播放器以浮层形式挂在当前页面之上，不再通过路由跳转，
/// 因此任何页面（浏览器 / 下载）都可以提交同一个请求。
class PlayerRequest {
  const PlayerRequest({
    required this.url,
    this.title = '',
    this.referer,
    this.local = false,
  });

  final String url;
  final String title;
  final String? referer;

  /// true 表示播放设备上的本地文件（已下载 / 已转换的内容）
  final bool local;
}
