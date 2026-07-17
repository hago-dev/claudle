import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tokenbar/data/providers/claude_code/claude_path_resolver.dart';
import 'package:tokenbar/data/statusline/statusline_installer.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('claudle_install');
    // resolveClaudeDirs 는 projects/ 가 있는 디렉토리만 claude 루트로 인정한다.
    Directory(p.join(tmp.path, 'projects')).createSync();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  StatuslineInstaller installer() => StatuslineInstaller(
    resolver: ClaudePathResolver(env: {'CLAUDE_CONFIG_DIR': tmp.path}),
  );

  File settingsFile() => File(p.join(tmp.path, 'settings.json'));
  void writeSettings(Object s) =>
      settingsFile().writeAsStringSync(json.encode(s));
  Map<String, dynamic> readSettings() =>
      json.decode(settingsFile().readAsStringSync()) as Map<String, dynamic>;

  group('check', () {
    test('settings.json 이 없으면 미설치', () {
      expect(installer().check(), StatuslineState.notInstalled);
    });

    test('statusLine 키가 없으면 미설치', () {
      writeSettings(const {'env': {}});
      expect(installer().check(), StatuslineState.notInstalled);
    });

    test('남의 statusLine 이 있으면 foreign — 건드리면 안 되는 상태', () {
      writeSettings(const {
        'statusLine': {
          'type': 'command',
          'command': 'bun x ccusage statusline',
        },
      });
      expect(installer().check(), StatuslineState.foreign);
    });

    test('우리 것이 깔려 있으면 installed', () {
      installer().install();
      expect(installer().check(), StatuslineState.installed);
    });

    test('settings.json 이 깨져 있어도 죽지 않는다 — 2초마다 도는 폴링이 부른다', () {
      settingsFile().writeAsStringSync('{ 이건 JSON 이 아니다');
      expect(installer().check, returnsNormally);
    });
  });

  group('install', () {
    test('실행 가능한 스크립트를 만든다', () {
      installer().install();
      final script = File(p.join(tmp.path, 'claudle-statusline.sh'));
      expect(script.existsSync(), isTrue);
      // 실행 권한이 없으면 CC 가 훅을 못 돌린다.
      final mode = script.statSync().mode & 0x49; // --x--x--x
      expect(mode, isNot(0), reason: '실행 비트가 없다');
    });

    test('기존 settings 를 보존한다 — env/permissions 를 날리지 않는다', () {
      writeSettings(const {
        'env': {'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE': '70'},
        'permissions': {
          'allow': ['Bash(ls)'],
        },
        'theme': 'dark',
      });
      installer().install();
      final s = readSettings();
      expect(s['env'], const {'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE': '70'});
      expect(s['permissions'], const {
        'allow': ['Bash(ls)'],
      });
      expect(s['theme'], 'dark');
      expect(
        (s['statusLine'] as Map)['command'],
        contains('claudle-statusline'),
      );
    });

    test('남의 statusLine 은 덮어쓰지 않는다 — 그냥 거부한다', () {
      writeSettings(const {
        'statusLine': {
          'type': 'command',
          'command': 'bun x ccusage statusline',
        },
      });
      expect(() => installer().install(), throwsStateError);
      expect(
        (readSettings()['statusLine'] as Map)['command'],
        'bun x ccusage statusline',
      );
    });

    test('두 번 설치해도 같은 상태 — 중복 배선 없음', () {
      installer().install();
      installer().install();
      expect(installer().check(), StatuslineState.installed);
    });
  });

  group('syncScript — 앱이 업데이트되면 깔린 스크립트도 따라와야 한다', () {
    File script() => File(p.join(tmp.path, 'claudle-statusline.sh'));

    test('낡은 사본을 현재 내용으로 덮는다', () {
      installer().install();
      final fresh = script().readAsStringSync();
      // 옛 버전이 깔려 있는 상황(앱만 업데이트된 뒤).
      script().writeAsStringSync('#!/bin/sh\n# 옛날 스크립트\ncat > /dev/null\n');

      installer().syncScript();

      expect(script().readAsStringSync(), fresh);
      // 덮어쓴 뒤에도 실행 비트가 남아야 한다 — 없으면 CC 가 훅을 못 돌린다.
      expect(script().statSync().mode & 0x49, isNot(0));
    });

    test('배선이 안 됐으면 아무것도 안 만든다 — 몰래 깔지 않는다', () {
      installer().syncScript();
      expect(script().existsSync(), isFalse);
    });

    test('남의 statusLine 이면 손대지 않는다', () {
      writeSettings(const {
        'statusLine': {
          'type': 'command',
          'command': 'bun x ccusage statusline',
        },
      });
      installer().syncScript();
      expect(script().existsSync(), isFalse);
    });
  });

  group('생성된 스크립트가 실제로 동작한다', () {
    /// 스크립트에 페이로드를 먹이고 stdout(=상태줄 텍스트)을 돌려준다.
    Future<String> feed(String payload) async {
      final proc = await Process.start('sh', [
        p.join(tmp.path, 'claudle-statusline.sh'),
      ]);
      proc.stdin.write(payload);
      await proc.stdin.close();
      final out = await proc.stdout.transform(utf8.decoder).join();
      expect(await proc.exitCode, 0);
      return out;
    }

    File dumpOf(String sid) =>
        File(p.join(tmp.path, 'claudle', 'sessions', '$sid.json'));

    test('세션마다 제 파일로 떨군다 — 서로 덮어쓰지 않는다', () async {
      installer().install();
      const a = '{"session_id":"aaa-1","context_window":{"n":1}}';
      const b = '{"session_id":"bbb-2","context_window":{"n":2}}';
      await feed(a);
      await feed(b);
      // 둘 다 살아있어야 한다 — 한 파일을 공유하면 뒤엣것만 남는다.
      expect(dumpOf('aaa-1').readAsStringSync(), a);
      expect(dumpOf('bbb-2').readAsStringSync(), b);
    });

    test('상태줄 텍스트는 비운다 — 없던 상태줄이 생기지 않게', () async {
      installer().install();
      expect(await feed('{"session_id":"s1","context_window":{}}'), '');
    });

    test('같은 세션이 다시 그리면 제 파일만 갱신', () async {
      installer().install();
      await feed('{"session_id":"s1","context_window":{"n":1}}');
      await feed('{"session_id":"s1","context_window":{"n":2}}');
      expect(dumpOf('s1').readAsStringSync(), contains('"n":2'));
      expect(
        Directory(p.join(tmp.path, 'claudle', 'sessions')).listSync().length,
        1,
      );
    });

    test('session_id 가 없어도 죽지 않는다', () async {
      installer().install();
      await feed('{"context_window":{"n":1}}');
      // 파일명으로 쓸 게 없으면 버리든 unknown 으로 두든, 죽지만 않으면 된다.
      expect(
        Directory(p.join(tmp.path, 'claudle', 'sessions')).existsSync(),
        isTrue,
      );
    });
  });
}
