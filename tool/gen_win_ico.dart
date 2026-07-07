// Windows 트레이 아이콘 생성기: PNG 트레이 매트릭스 → 정방 투명 패딩 → **DIB(.ico)**.
//
// Windows 시스템 트레이는 `LoadImage(IMAGE_ICON, LR_LOADFROMFILE)` 로 아이콘을 읽는다
// (tray_manager 0.5.3 의 setIcon 구현). 이 API 는 아이콘 항목을 **BITMAPINFOHEADER(DIB)**
// 로 파싱하므로, PNG-압축 항목(PNG-in-ICO)은 첫 DWORD 를 biSize 로 읽다 PNG 매직(0x474E5089)
// 을 만나 거부하고 NULL 을 돌려준다 → 트레이 아이콘이 빈칸이 된다. (PNG 항목은 LoadImage 가
// 아니라 LoadIconWithScaleDown/WIC 만 디코드한다.) 따라서 **무압축 32bpp BGRA DIB + AND 마스크**
// 형식으로 직접 인코딩한다.
//
// 소스 PNG(러닝 푸들 56×34 비정방)는 긴 변 기준 정방 캔버스에 투명 패딩 후 중앙 배치해
// 종횡비를 보존한다(Windows 가 표시 크기 16px 로 스케일).
//
// 실행:   fvm dart run tool/gen_win_ico.dart   (프로젝트 루트에서)
// 대상:   assets/tray/run/run_*.png  및  assets/tray/icon.png → 각 옆에 .ico 생성.
// 검증:   각 .ico 의 데이터 오프셋(22)이 `28 00 00 00`(=40, BITMAPINFOHEADER)로 시작해야 한다.
// 산출물(.ico)은 레포에 커밋하므로 빌더가 이 툴을 다시 돌릴 필요는 없다(재생성용).
//
// 의존성: dev_dependencies 의 `image` 패키지(PNG 디코드·리사이즈·합성 전용, 런타임 미포함).

import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 정방 [im] 을 단일 이미지 DIB 형식 .ico 바이트로 인코딩.
/// LoadImage(IMAGE_ICON) 가 디코드할 수 있는 무압축 32bpp BGRA + 1bpp AND 마스크.
Uint8List encodeDibIco(img.Image im) {
  final w = im.width, h = im.height;
  final xorSize = w * h * 4; // 32bpp BGRA
  final andRowBytes = ((w + 31) ~/ 32) * 4; // 1bpp, 행을 4바이트 경계로 패딩
  final andSize = andRowBytes * h;
  final dibSize = 40 + xorSize + andSize; // BITMAPINFOHEADER + XOR + AND

  final head = ByteData(22);
  // ICONDIR
  head.setUint16(0, 0, Endian.little); // reserved
  head.setUint16(2, 1, Endian.little); // type = 1 (icon)
  head.setUint16(4, 1, Endian.little); // count = 1
  // ICONDIRENTRY
  head.setUint8(6, w >= 256 ? 0 : w); // width (0 == 256)
  head.setUint8(7, h >= 256 ? 0 : h); // height
  head.setUint8(8, 0); // color count
  head.setUint8(9, 0); // reserved
  head.setUint16(10, 1, Endian.little); // planes
  head.setUint16(12, 32, Endian.little); // bit count
  head.setUint32(14, dibSize, Endian.little); // bytes in resource
  head.setUint32(18, 22, Endian.little); // image offset

  final bih = ByteData(40);
  bih.setUint32(0, 40, Endian.little); // biSize (BITMAPINFOHEADER)
  bih.setInt32(4, w, Endian.little); // biWidth
  bih.setInt32(8, h * 2, Endian.little); // biHeight = XOR + AND(마스크) 이므로 2배
  bih.setUint16(12, 1, Endian.little); // biPlanes
  bih.setUint16(14, 32, Endian.little); // biBitCount
  bih.setUint32(16, 0, Endian.little); // biCompression = BI_RGB
  // biSizeImage=0(BI_RGB 허용) 및 나머지 필드 0.

  final xor = Uint8List(xorSize);
  var o = 0;
  for (var y = h - 1; y >= 0; y--) {
    // DIB 는 bottom-up
    for (var x = 0; x < w; x++) {
      final px = im.getPixel(x, y);
      xor[o++] = px.b.toInt();
      xor[o++] = px.g.toInt();
      xor[o++] = px.r.toInt();
      xor[o++] = px.a.toInt();
    }
  }
  // AND 마스크: 전부 0 = "모든 픽셀 그림"(투명도는 알파가 처리).

  final out = BytesBuilder()
    ..add(head.buffer.asUint8List())
    ..add(bih.buffer.asUint8List())
    ..add(xor)
    ..add(Uint8List(andSize));
  return out.toBytes();
}

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
    File(icoPath).writeAsBytesSync(encodeDibIco(canvas));
    count++;
  }
  stdout.writeln('generated $count DIB .ico file(s) from tray PNGs');
}
