/// 设备的 APK 安装能力。
///
/// Android 不允许普通应用静默安装：只有被授予 `INSTALL_PACKAGES`
/// （系统签名 / 预装 priv-app）或拥有 root 的设备才能跳过确认框。
/// 这里如实暴露探测结果，界面据此提示，能力不足时自动回退系统安装器。
class InstallerCapability {
  const InstallerCapability({
    required this.privileged,
    required this.root,
    required this.canSilent,
    required this.detail,
  });

  /// 已获得系统安装权限（系统签名 / priv-app）
  final bool privileged;

  /// 设备已 root，可用 su 执行 pm install
  final bool root;

  /// 是否可以在无确认框的情况下完成安装
  final bool canSilent;

  /// 面向用户的说明
  final String detail;

  static const unknown = InstallerCapability(
    privileged: false,
    root: false,
    canSilent: false,
    detail: '尚未探测安装能力',
  );

  String get modeLabel {
    if (privileged) return '静默安装 · 系统权限';
    if (root) return '静默安装 · root';
    return '系统安装器 · 需确认';
  }

  factory InstallerCapability.fromMap(Map<dynamic, dynamic> map) {
    return InstallerCapability(
      privileged: map['privileged'] == true,
      root: map['root'] == true,
      canSilent: map['canSilent'] == true,
      detail: map['detail'] is String ? map['detail'] as String : '',
    );
  }
}

/// 一次安装请求的结果。
class InstallResult {
  const InstallResult({
    required this.ok,
    required this.mode,
    required this.message,
  });

  final bool ok;

  /// privileged / root / system / none
  final String mode;
  final String message;

  bool get silent => ok && (mode == 'privileged' || mode == 'root');

  String get modeLabel => switch (mode) {
        'privileged' => '静默（系统权限）',
        'root' => '静默（root）',
        'system' => '系统安装器',
        _ => '未执行',
      };

  static const canceled = InstallResult(
    ok: false,
    mode: 'none',
    message: '已取消',
  );

  factory InstallResult.fromMap(Map<dynamic, dynamic> map) {
    return InstallResult(
      ok: map['ok'] == true,
      mode: map['mode'] is String ? map['mode'] as String : 'none',
      message: map['message'] is String ? map['message'] as String : '',
    );
  }
}
