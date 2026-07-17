import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../domain/models/context_gauge.dart';
import 'claude_path_resolver.dart';

/// CC statusline 이 덤프한 페이로드 → [ContextGauge].
///
/// 컨텍스트 윈도우 크기는 세션 JSONL 어디에도 없다(`model` 은 `claude-opus-4-8`
/// 까지만 남아 200k/1M 구분 불가). CC 가 statusline 커맨드에 넘겨주는
/// `context_window.context_window_size` 가 유일한 로컬 출처라 이 경로를 쓴다.
/// 훅 배선/스크립트 생성은 [StatuslineInstaller] 가 한다(사용자는 설정을 손대지 않는다).
///
/// 라이브 판정은 하지 않는다 — 죽은 세션의 낡은 덤프는 그대로 남지만, 화면이 이미
/// "누가 도는가"를 알고 있어([AgentRun]) sessionId 로 조인하면 자연히 걸러진다.
/// 여기서 별도의 시간 창을 두면 그 판정과 어긋난다.
class ContextGaugeReader {
  final ClaudePathResolver resolver;
  ContextGaugeReader({ClaudePathResolver? resolver})
    : resolver = resolver ?? ClaudePathResolver();

  /// statusline 덤프 디렉토리들(claude 루트마다 하나).
  List<Directory> _dumpDirs() => resolver
      .resolveClaudeDirs()
      .map((d) => Directory(p.join(d, 'claudle', 'sessions')))
      .where((d) => d.existsSync())
      .toList();

  /// 세션id → 게이지. 덤프가 없으면(=statusline 미설정) 빈 맵.
  ///
  /// 한 세션의 덤프가 깨져 있어도 나머지는 살린다 — statusline 이 쓰는 중이면
  /// 조각난 JSON 을 볼 수 있고, 그건 다음 틱에 낫는다.
  Map<String, ContextGauge> readAll() {
    final out = <String, ContextGauge>{};
    final pct = _pctOverride();
    for (final dir in _dumpDirs()) {
      for (final e in dir.listSync()) {
        if (e is! File || !e.path.endsWith('.json')) continue;
        try {
          final payload = json.decode(e.readAsStringSync());
          if (payload is! Map<String, dynamic>) continue;
          final g = parse(
            payload,
            pctOverride: pct,
            updatedAt: e.lastModifiedSync(),
          );
          if (g != null && g.sessionId.isNotEmpty) out[g.sessionId] = g;
        } on FormatException {
          continue;
        } on FileSystemException {
          continue;
        }
      }
    }
    return out;
  }

  /// `~/.claude/settings.json` 의 env 에서 override 를 읽는다.
  int? _pctOverride() {
    for (final d in resolver.resolveClaudeDirs()) {
      final f = File(p.join(d, 'settings.json'));
      if (!f.existsSync()) continue;
      try {
        final s = json.decode(f.readAsStringSync());
        if (s is Map<String, dynamic>) {
          final v = pctOverrideFrom(s);
          if (v != null) return v;
        }
      } on FormatException {
        continue;
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  /// 페이로드 파싱(순수). 윈도우를 모르면 **추측하지 않고** null.
  static ContextGauge? parse(
    Map<String, dynamic> payload, {
    required int? pctOverride,
    required DateTime updatedAt,
  }) {
    final cw = payload['context_window'];
    if (cw is! Map<String, dynamic>) return null;

    final window = (cw['context_window_size'] as num?)?.toInt() ?? 0;
    if (window <= 0) return null;

    final usage = cw['current_usage'];
    if (usage is! Map<String, dynamic>) return null;

    return ContextGauge(
      sessionId: payload['session_id'] as String? ?? '',
      usedTokens: ContextGauge.tokensOf(usage),
      windowSize: window,
      pctOverride: pctOverride,
      updatedAt: updatedAt,
    );
  }

  /// settings.json 맵에서 `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` 추출.
  static int? pctOverrideFrom(Map<String, dynamic> settings) {
    final env = settings['env'];
    if (env is! Map) return null;
    final raw = env['CLAUDE_AUTOCOMPACT_PCT_OVERRIDE'];
    if (raw == null) return null;
    return int.tryParse(raw.toString());
  }
}
