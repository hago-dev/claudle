import 'dart:io';

/// 크로스플랫폼 사용자 홈 디렉토리.
///
/// - Windows: `USERPROFILE`(예: `C:\Users\me`). 없으면 `HOMEDRIVE`+`HOMEPATH` 합성.
/// - 그 외(macOS/Linux): `HOME`.
///
/// [env] 를 주입하면 그걸 사용(테스트용). 없으면 [Platform.environment].
/// 결정 불가 시 null.
String? userHome([Map<String, String>? env]) {
  final e = env ?? Platform.environment;
  if (Platform.isWindows) {
    final up = e['USERPROFILE'];
    if (up != null && up.isNotEmpty) return up;
    final drive = e['HOMEDRIVE'];
    final path = e['HOMEPATH'];
    if (drive != null && drive.isNotEmpty && path != null && path.isNotEmpty) {
      return '$drive$path';
    }
    return null;
  }
  final home = e['HOME'];
  return (home == null || home.isEmpty) ? null : home;
}
