import 'dart:io';

import 'package:path/path.dart' as p;

import 'user_home.dart';

/// cwd(실제 작업 디렉토리)에서 **프로젝트 루트**를 찾는다.
///
/// 하위 폴더에서 `claude` 를 실행하면 cwd basename 이 'src'/'dto'/'customer'
/// 같은 임의값이 되어 프로젝트 단위 집계가 깨진다. 가장 가까운 `.git` 을 가진
/// 조상 디렉토리(= git 저장소 루트)로 묶어 프로젝트 단위로 합산한다.
///
/// - `.git` 은 디렉토리(일반) 또는 파일(worktree/submodule) 둘 다 가능.
/// - `$HOME` 을 넘어 올라가지 않는다(홈-레벨 dotfiles 저장소가 무관한 cwd 들을
///   집어삼키는 것을 방지). 홈 미만에서 못 찾으면 정규화된 cwd 를 그대로 반환.
/// - **절대경로만** walk 한다(인코딩 project 키·상대 문자열이 넘어와도 방어).
/// - 입력/폴백 모두 `p.normalize` 로 정규화 → 트레일링 슬래시 등으로 키가 갈라지지 않음.
/// - 결과는 원본 cwd 기준 캐시(경로→루트 매핑은 앱 실행 중 불변).
///
/// 참고: 이 함수는 블로킹 파일시스템 I/O(existsSync)를 한다 → **ingest 시 1회 호출해
/// project_root 컬럼에 저장**하고(대시보드 표시 경로에서 호출 금지) UI 스레드 I/O 를 피한다.
final Map<String, String> _rootCache = {};

String projectRootOf(String cwd) {
  if (cwd.isEmpty || !p.isAbsolute(cwd)) return cwd;
  final hit = _rootCache[cwd];
  if (hit != null) return hit;
  final homeEnv = userHome();
  final home =
      (homeEnv == null || homeEnv.isEmpty) ? null : p.normalize(homeEnv);
  final start = p.normalize(cwd);
  var dir = start;
  while (true) {
    if (home != null && dir == home) break; // 홈은 프로젝트 경계(초과 금지)
    final git = p.join(dir, '.git');
    if (Directory(git).existsSync() || File(git).existsSync()) {
      return _rootCache[cwd] = dir;
    }
    final parent = p.dirname(dir);
    if (parent == dir) break; // 파일시스템 루트 도달
    dir = parent;
  }
  return _rootCache[cwd] = start; // git 루트 없음 → 정규화된 cwd
}
