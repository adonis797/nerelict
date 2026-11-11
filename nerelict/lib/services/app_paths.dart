import 'dart:io';

/// 统一的路径配置与拼接工具。
///
/// 设计约束：
/// - 不读取运行时工作目录，不假设仓库位于某个固定位置，不写死盘符；
/// - 所有目录都基于调用方显式提供的基准解析，配置缺失时回退到系统临时目录；
/// - 环境变量可覆盖，覆盖值支持绝对路径与相对路径，异常值自动回退；
/// - 只依赖 `dart:io`，不引入新依赖，App 与主机端脚本都能复用。

/// 下载目录覆盖变量（主机端脚本或自定义部署可用）。
const String kDownloadDirEnv = 'NERELICT_DOWNLOAD_DIR';

/// 安装确认脚本目录覆盖变量（仅主机端验证脚本使用，未设置即跳过相关断言）。
const String kInstallSkillDirEnv = 'NERELICT_INSTALL_SKILL_DIR';

/// 项目根覆盖变量（仅当脚本无法从自身位置定位时使用）。
const String kProjectRootEnv = 'NERELICT_PROJECT_ROOT';

/// 默认下载子目录名，保持原有命名。
const String kDownloadDirName = 'Nerelict';

/// 清理配置值：未设置或全空白都视为未配置。
String? cleanEnvValue(String? raw) {
  if (raw == null) return null;
  final value = raw.trim();
  return value.isEmpty ? null : value;
}

/// 读取环境配置。未设置、全空白返回 null。
String? readEnvPath(String key) => cleanEnvValue(Platform.environment[key]);

/// 平台无关的路径拼接。
///
/// 任一为空时返回另一方；清理 base 尾部与 child 头部多余的分隔符，
/// 避免重复分隔符。不解析 `..`，由 [resolveConfiguredPath] 负责拒绝。
String joinPath(String base, String child) {
  if (base.isEmpty) return child;
  if (child.isEmpty) return base;
  final b = base.replaceAll(RegExp(r'[/\\]+$'), '');
  final c = child.replaceAll(RegExp(r'^[/\\]+'), '');
  if (c.isEmpty) return b.isEmpty ? Platform.pathSeparator : b;
  if (b.isEmpty) return '${Platform.pathSeparator}$c';
  return '$b${Platform.pathSeparator}$c';
}

/// 识别绝对路径：POSIX 根、UNC、Windows 盘符。
bool _isAbsolute(String value) =>
    value.startsWith('/') ||
    value.startsWith('\\') ||
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);

/// 把配置值解析成可用路径。
///
/// - null / 空白 -> null（调用方回退默认值）；
/// - 含 `..` 段 -> null（拒绝路径穿越）；
/// - 绝对路径 -> 清理尾部分隔符后返回；
/// - 相对路径 -> 相对 [relativeBase] 拼接，不依赖运行目录。
String? resolveConfiguredPath(String? value, {required String relativeBase}) {
  final v = cleanEnvValue(value);
  if (v == null) return null;
  final segments = v.split(RegExp(r'[/\\]'));
  if (segments.contains('..')) return null;
  if (_isAbsolute(v)) return v.replaceAll(RegExp(r'[/\\]+$'), '');
  final parts = segments.where((s) => s.isNotEmpty && s != '.').toList();
  if (parts.isEmpty) return null;
  var result = relativeBase;
  for (final part in parts) {
    result = joinPath(result, part);
  }
  return result;
}

/// 解析并创建默认输出目录。
///
/// 优先级：环境变量 [configured] > [fallbackRoot]/[name] 默认值。
/// 配置值非法、指向文件或目录不可创建时自动回退默认值，保证功能不中断。
Future<Directory> defaultOutputDirectory({
  String? configured,
  Future<Directory> Function()? fallbackRoot,
  String name = kDownloadDirName,
}) async {
  final root = await (fallbackRoot?.call() ??
      Future<Directory>.value(Directory.systemTemp));
  final fallback = Directory(joinPath(root.path, name));
  final resolved = resolveConfiguredPath(configured, relativeBase: root.path);
  final target = resolved == null ? fallback : Directory(resolved);
  try {
    if (!await target.exists()) await target.create(recursive: true);
    if (await FileSystemEntity.type(target.path) !=
        FileSystemEntityType.directory) {
      throw const FileSystemException('configured path is not a directory');
    }
    return target;
  } catch (_) {
    if (!await fallback.exists()) await fallback.create(recursive: true);
    return fallback;
  }
}

/// 解析端口配置：缺失、空白、非数字、越界都回退到 [fallback]。
int parseConfiguredPort(String? raw, {required int fallback}) {
  final value = int.tryParse(cleanEnvValue(raw) ?? '');
  return (value != null && value > 0 && value <= 65535) ? value : fallback;
}
