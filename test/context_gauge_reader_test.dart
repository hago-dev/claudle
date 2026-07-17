import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tokenbar/data/providers/claude_code/claude_path_resolver.dart';
import 'package:tokenbar/data/providers/claude_code/context_gauge_reader.dart';

final _updatedAt = DateTime(2026, 7, 17);

/// CC statusline 이 stdin 으로 주는 페이로드(필요한 부분만).
Map<String, dynamic> _payload({
  int window = 1000000,
  int cacheRead = 570000,
  int output = 4000,
}) => {
  'session_id': 'abc-123',
  'model': const {'id': 'claude-opus-4-8', 'display_name': 'Opus 4.8'},
  'context_window': {
    'context_window_size': window,
    'current_usage': {
      'input_tokens': 0,
      'cache_creation_input_tokens': 0,
      'cache_read_input_tokens': cacheRead,
      'output_tokens': output,
    },
    // 분모가 달라 우리는 안 쓰는 필드 — 있어도 무시해야 한다.
    'remaining_percentage': 43,
  },
};

void main() {
  group('parse', () {
    test('페이로드에서 세션·토큰·윈도우를 뽑는다', () {
      final g = ContextGaugeReader.parse(
        _payload(),
        pctOverride: 70,
        updatedAt: _updatedAt,
      )!;
      expect(g.sessionId, 'abc-123');
      expect(g.usedTokens, 574000);
      expect(g.windowSize, 1000000);
      expect(g.pctOverride, 70);
    });

    test('statusline 의 remaining_percentage 를 그대로 쓰지 않는다', () {
      // 페이로드는 43% 남았다고 하지만, auto-compact 기준으로는 18% 다.
      final g = ContextGaugeReader.parse(
        _payload(),
        pctOverride: 70,
        updatedAt: _updatedAt,
      )!;
      expect(g.remainingPercent, 18);
    });

    test('context_window 가 없으면(구버전 CC) null', () {
      expect(
        ContextGaugeReader.parse(
          const {'session_id': 'x'},
          pctOverride: null,
          updatedAt: _updatedAt,
        ),
        isNull,
      );
    });

    test('윈도우 크기가 0 이면 null — 추측하지 않는다', () {
      expect(
        ContextGaugeReader.parse(
          _payload(window: 0),
          pctOverride: null,
          updatedAt: _updatedAt,
        ),
        isNull,
      );
    });
  });

  group('read — 디스크에서 끝까지', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('claudle_gauge');
      // resolveClaudeDirs 는 projects/ 가 있는 디렉토리만 claude 루트로 인정한다.
      Directory(p.join(tmp.path, 'projects')).createSync();
      Directory(p.join(tmp.path, 'claudle')).createSync();
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    ContextGaugeReader reader() => ContextGaugeReader(
      resolver: ClaudePathResolver(env: {'CLAUDE_CONFIG_DIR': tmp.path}),
    );

    void writeDump(Map<String, dynamic> payload) {
      final dir = Directory(p.join(tmp.path, 'claudle', 'sessions'))
        ..createSync(recursive: true);
      File(
        p.join(dir.path, '${payload['session_id']}.json'),
      ).writeAsStringSync(json.encode(payload));
    }

    void writeSettings(Object settings) => File(
      p.join(tmp.path, 'settings.json'),
    ).writeAsStringSync(json.encode(settings));

    test('덤프 + settings.json override 를 합쳐 sessionId 로 색인한다', () {
      writeDump(_payload());
      writeSettings(const {
        'env': {'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE': '70'},
      });
      final g = reader().readAll()['abc-123']!;
      expect(g.usedTokens, 574000);
      expect(g.remainingPercent, 18);
    });

    test('세션이 여럿이면 각각 제 게이지를 준다', () {
      writeDump(_payload());
      writeDump({
        ..._payload(cacheRead: 100000, output: 0),
        'session_id': 'zzz-9',
      });
      writeSettings(const {
        'env': {'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE': '70'},
      });
      final all = reader().readAll();
      expect(all.keys.toSet(), {'abc-123', 'zzz-9'});
      expect(all['abc-123']!.usedTokens, 574000);
      expect(all['zzz-9']!.usedTokens, 100000);
    });

    test('settings.json 에 override 가 없으면 예약분만 적용', () {
      writeDump(_payload());
      writeSettings(const {'env': {}});
      // 임계값 987000 → (987000-574000)/987000 = 41.8% → 42
      expect(reader().readAll()['abc-123']!.remainingPercent, 42);
    });

    test('덤프가 없으면(statusline 미설정) 빈 맵', () {
      writeSettings(const {'env': {}});
      expect(reader().readAll(), isEmpty);
    });

    test('한 세션의 덤프가 조각나도 나머지는 살린다', () {
      writeDump(_payload());
      writeSettings(const {'env': {}});
      File(
        p.join(tmp.path, 'claudle', 'sessions', 'broken.json'),
      ).writeAsStringSync('{"context_window":{"conte');
      final all = reader().readAll();
      expect(all.keys, ['abc-123']);
    });
  });

  group('pctOverrideFrom — settings.json 의 env', () {
    test('문자열 숫자를 읽는다', () {
      expect(
        ContextGaugeReader.pctOverrideFrom(const {
          'env': {'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE': '70'},
        }),
        70,
      );
    });

    test('없으면 null', () {
      expect(ContextGaugeReader.pctOverrideFrom(const {}), isNull);
      expect(ContextGaugeReader.pctOverrideFrom(const {'env': {}}), isNull);
    });

    test('숫자가 아니면 null', () {
      expect(
        ContextGaugeReader.pctOverrideFrom(const {
          'env': {'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE': 'nope'},
        }),
        isNull,
      );
    });
  });
}
