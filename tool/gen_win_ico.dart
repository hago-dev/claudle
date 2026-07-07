// Windows 트레이 아이콘 생성기: PNG 트레이 매트릭스 → 정방 투명 패딩 → .ico.
//
// Windows 시스템 트레이는 `LoadImage(IMAGE_ICON, LR_LOADFROMFILE)` 로 아이콘을 읽어
// **.ico 파일만** 로드한다(PNG 는 실패 → 빈 아이콘). 소스 PNG(러닝 푸들 56×34 비정방)를
// 그대로 16×16 슬롯에 넣으면 가로로 찌부되므로, 긴 변 기준 정방 캔버스에 투명 패딩 후
// 중앙 배치해 종횡비를 보존한다. Windows 가 실제 표시 크기(16px)로 스케일한다.
//
// 실행:   fvm dart run tool/gen_win_ico.dart   (프로젝트 루트에서)
// 대상:   assets/tray/run/run_*.png  및  assets/tray/icon.png → 각 옆에 .ico 생성.
// 산출물(.ico)은 레포에 커밋하므로 빌더가 이 툴을 다시 돌릴 필요는 없다(재생성용).
//
// 의존성: dev_dependencies 의 `image` 패키지(런타임 앱 번들엔 포함되지 않음).

import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  final runDir = Directory('assets/tray/run');
  final targets = <File>[
    if (runDir.existsSync())
      ...runDir.listSync().whereType<File>().where(
            (f) => f.path.toLowerCase().endsWith('.png'),
          ),
    File('assets/tray/icon.png'),
  ];

  var count = 0;
  for (final f in targets) {
    if (!f.existsSync()) continue;
    final src = img.decodePng(f.readAsBytesSync());
    if (src == null) {
      stderr.writeln('skip (png decode fail): ${f.path}');
      continue;
    }
    final side = src.width > src.height ? src.width : src.height;
    final canvas = img.Image(width: side, height: side, numChannels: 4);
    img.compositeImage(canvas, src, center: true);
    final icoPath = f.path.replaceAll(RegExp(r'\.png$'), '.ico');
    File(icoPath).writeAsBytesSync(img.encodeIco(canvas));
    count++;
  }
  stdout.writeln('generated $count .ico file(s) from tray PNGs');
}
