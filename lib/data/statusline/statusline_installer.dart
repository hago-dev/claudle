import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../providers/claude_code/claude_path_resolver.dart';

/// statusline 훅 배선 상태.
enum StatuslineState {
  /// claude 루트를 못 찾음(CC 미설치 등).
  unavailable,

  /// statusLine 설정 없음 — 설치 가능.
  notInstalled,

  /// 우리 훅이 배선됨.
  installed,

  /// 남의 statusLine 이 있음. 덮으면 남의 상태줄이 죽으니 건드리지 않는다.
  foreign,
}

/// 컨텍스트 게이지용 statusline 훅을 앱이 직접 배선한다.
///
/// **Deep Module**: 호출자는 [check]/[install] 두 개만 안다. 스크립트 내용·경로·
/// settings.json 병합·플랫폼 분기는 전부 여기 숨는다.
///
/// 왜 앱이 설치하나: 게이지에 필요한 컨텍스트 윈도우 크기가 세션 JSONL 에 없고
/// (`model` 은 `claude-opus-4-8` 까지만 남아 200k/1M 구분 불가) CC 가 statusline
/// 커맨드에 넘겨주는 페이로드가 유일한 로컬 출처다. 그렇다고 배포 대상 전원에게
/// settings.json 을 손으로 고치라고 할 수는 없다.
///
/// 안전 규칙(불가침): 남의 statusLine 은 덮지 않는다. settings.json 은 병합만 한다.
class StatuslineInstaller {
  /// 우리가 깐 훅을 알아보는 표식(파일명에 들어간다).
  static const _scriptStem = 'claudle-statusline';

  final ClaudePathResolver resolver;
  final bool isWindows;

  StatuslineInstaller({ClaudePathResolver? resolver, bool? isWindows})
    : resolver = resolver ?? ClaudePathResolver(),
      isWindows = isWindows ?? Platform.isWindows;

  String? get _claudeDir {
    final dirs = resolver.resolveClaudeDirs();
    return dirs.isEmpty ? null : dirs.first;
  }

  File? get _settingsFile {
    final d = _claudeDir;
    return d == null ? null : File(p.join(d, 'settings.json'));
  }

  String get _scriptName => '$_scriptStem.${isWindows ? 'ps1' : 'sh'}';

  /// 지금 배선 상태.
  ///
  /// 폴링(2s)이 부르므로 던지지 않는다 — settings 를 못 읽으면 "모른다"로 보고
  /// 판단을 [install] 로 미룬다(거기선 크게 실패해야 한다).
  StatuslineState check() {
    final f = _settingsFile;
    if (f == null) return StatuslineState.unavailable;
    if (!f.existsSync()) return StatuslineState.notInstalled;

    final Map<String, dynamic> s;
    try {
      s = _readSettings(f);
    } on StateError {
      return StatuslineState.unavailable;
    }
    final sl = s['statusLine'];
    if (sl == null) return StatuslineState.notInstalled;

    final cmd = sl is Map ? (sl['command']?.toString() ?? '') : '';
    return cmd.contains(_scriptStem)
        ? StatuslineState.installed
        : StatuslineState.foreign;
  }

  /// 스크립트를 깔고 settings.json 에 배선한다.
  ///
  /// 남의 statusLine 이 있으면 [StateError] — 호출자가 사용자에게 알려야 한다.
  void install() {
    final state = check();
    if (state == StatuslineState.foreign) {
      throw StateError('이미 다른 statusLine 이 설정돼 있어 덮어쓰지 않았습니다.');
    }
    final dir = _claudeDir;
    if (dir == null) throw StateError('Claude Code 설정 디렉토리를 찾지 못했습니다.');

    final scriptPath = _writeScript(dir);

    final f = _settingsFile!;
    final s = f.existsSync() ? _readSettings(f) : <String, dynamic>{};
    s['statusLine'] = {'type': 'command', 'command': _command(scriptPath)};
    // 원자적 교체 — 쓰다 죽어서 사용자 설정을 반토막 내지 않게.
    final tmp = File('${f.path}.claudle.tmp');
    tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(s));
    tmp.renameSync(f.path);
  }

  /// 깔린 스크립트를 현재 내용으로 맞춘다. 배선이 없거나 남의 것이면 아무것도 안 한다.
  ///
  /// 스크립트는 앱이 만드는 **산출물**이다 — 앱만 업데이트되면 사본이 갈라져 조용히
  /// 옛 동작을 한다(세션별 분리 이전 스크립트가 남아 한 파일만 쓰는 식). 앱 시작마다
  /// 맞춰서 그 드리프트를 없앤다. settings.json 은 건드리지 않는다.
  void syncScript() {
    if (check() != StatuslineState.installed) return;
    final dir = _claudeDir;
    if (dir == null) return;
    _writeScript(dir);
  }

  /// 스크립트를 쓰고(내용이 같으면 건너뛴다) 그 경로를 준다.
  String _writeScript(String claudeDir) {
    final path = p.join(claudeDir, _scriptName);
    final body = _scriptBody(claudeDir);
    final f = File(path);
    if (f.existsSync() && f.readAsStringSync() == body) return path;
    f.writeAsStringSync(body);
    if (!isWindows) Process.runSync('chmod', ['+x', path]);
    return path;
  }

  String _command(String scriptPath) => isWindows
      ? 'powershell -NoProfile -ExecutionPolicy Bypass -File "$scriptPath"'
      : scriptPath;

  Map<String, dynamic> _readSettings(File f) {
    try {
      final v = json.decode(f.readAsStringSync());
      return v is Map<String, dynamic> ? v : <String, dynamic>{};
    } on FormatException {
      // 못 읽는 settings 를 덮으면 사용자 설정이 날아간다 — 차라리 멈춘다.
      throw StateError('settings.json 을 읽을 수 없습니다(JSON 오류).');
    }
  }

  /// 페이로드를 받아 `<claude>/claudle/sessions/<session_id>.json` 으로 원자적으로
  /// 떨구는 스크립트. stdout 은 비운다 — 없던 상태줄이 생기지 않게.
  ///
  /// 세션마다 파일을 나누는 이유: 세션이 여럿이면 한 파일을 서로 덮어써 마지막에 그린
  /// 세션만 남는다. 게이지는 세션당 하나다.
  ///
  /// `session_id` 는 `sed` 로 뽑는다 — jq/python 은 있으리란 보장이 없다(POSIX 만 쓴다).
  String _scriptBody(String claudeDir) {
    final out = p.join(claudeDir, 'claudle', 'sessions');
    if (isWindows) {
      return '# Claudle 컨텍스트 게이지 — Claudle 이 자동 생성. 직접 고치지 마세요.\n'
          '\$dir = "$out"\n'
          'New-Item -ItemType Directory -Force -Path \$dir | Out-Null\n'
          '\$payload = [Console]::In.ReadToEnd()\n'
          '\$m = [regex]::Match(\$payload, \'"session_id"\\s*:\\s*"([^"]+)"\')\n'
          '\$sid = if (\$m.Success) { \$m.Groups[1].Value } else { "unknown" }\n'
          '\$tmp = Join-Path \$dir ".tmp.\$PID"\n'
          '\$payload | Set-Content -LiteralPath \$tmp -Encoding utf8 -NoNewline\n'
          'Move-Item -Force -LiteralPath \$tmp -Destination (Join-Path \$dir "\$sid.json")\n';
    }
    return '#!/bin/sh\n'
        '# Claudle 컨텍스트 게이지 — Claudle 이 자동 생성. 직접 고치지 마세요.\n'
        'set -eu\n'
        'dir="$out"\n'
        'mkdir -p "\$dir"\n'
        '# tmp 에 받아 원자적으로 교체 — 앱이 조각난 JSON 을 읽지 않게.\n'
        '# \$\$ 로 나눠 동시 렌더끼리 tmp 를 밟지 않게 한다.\n'
        'tmp="\$dir/.tmp.\$\$"\n'
        'cat > "\$tmp"\n'
        '# 세션당 한 파일 — 여럿이 한 파일을 쓰면 마지막 세션만 남는다.\n'
        'sid=\$(sed -n \'s/.*"session_id"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p\' "\$tmp" | head -1)\n'
        '[ -n "\$sid" ] || sid=unknown\n'
        'mv -f "\$tmp" "\$dir/\$sid.json"\n';
  }
}
