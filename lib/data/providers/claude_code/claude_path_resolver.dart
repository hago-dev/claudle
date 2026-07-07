import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/util/user_home.dart';

/// Claude Code 데이터 위치 해석 + JSONL 파일 나열. ccusage `getClaudePaths()` 규약.
///
///  - `CLAUDE_CONFIG_DIR`(쉼표 구분 다중 가능)를 우선.
///  - 없으면 `~/.config/claude`, `~/.claude` 후보 중 `projects/` 가 있는 것만.
///
/// 홈은 OS 별로 해석([userHome]): Windows=`USERPROFILE`, 그 외=`HOME`.
class ClaudePathResolver {
  final Map<String, String> _env;
  ClaudePathResolver({Map<String, String>? env})
      : _env = env ?? Platform.environment;

  /// `projects/` 를 가진 유효한 claude 루트 디렉토리들.
  List<String> resolveClaudeDirs() {
    final configured = _env['CLAUDE_CONFIG_DIR'];
    final List<String> candidates;
    if (configured != null && configured.trim().isNotEmpty) {
      candidates = configured.split(',').map((e) => e.trim()).toList();
    } else {
      final home = userHome(_env);
      if (home == null) return const [];
      candidates = [
        p.join(home, '.config', 'claude'),
        p.join(home, '.claude'),
      ];
    }
    return candidates
        .where((d) => Directory(p.join(d, 'projects')).existsSync())
        .toList();
  }

  /// 모든 루트의 `projects/**/*.jsonl`.
  List<File> jsonlFiles() {
    final files = <File>[];
    for (final dir in resolveClaudeDirs()) {
      final projects = Directory(p.join(dir, 'projects'));
      for (final e in projects.listSync(recursive: true, followLinks: false)) {
        if (e is File && e.path.endsWith('.jsonl')) files.add(e);
      }
    }
    return files;
  }

  /// 파일 경로에서 프로젝트명(= `projects/` 바로 아래 디렉토리명) 추출.
  /// 경로 구분자는 `/`(POSIX)·`\`(Windows) 모두 허용.
  static String? projectFromPath(String filePath) {
    final parts = filePath.split(RegExp(r'[/\\]'));
    final idx = parts.lastIndexOf('projects');
    if (idx >= 0 && idx + 1 < parts.length) return parts[idx + 1];
    return null;
  }
}
