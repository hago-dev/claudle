import AppKit
import Foundation

// 메뉴바 러닝 푸들: 회색 몸통 + 바이올렛(#7C5CFF) 아래→위 채움(사용량%).
// 프레임(달리는 모션) × 채움레벨 매트릭스를 컬러 PNG 로 생성.
let W = 56.0, H = 34.0
let nFrames = 6
let swingAmp = 4.5
let fillLevels = stride(from: 0, through: 100, by: 10).map { $0 } // 0,10,...,100
let dogMinY = 5.0, dogMaxY = 31.0 // 채움 기준 몸통 상하한

let gray = NSColor(calibratedRed: 0.60, green: 0.60, blue: 0.63, alpha: 1)
let violet = NSColor(calibratedRed: 124.0/255, green: 92.0/255, blue: 1.0, alpha: 1)

func newRep() -> NSBitmapImageRep {
  return NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}

// 검은 실루엣(알파=모양)을 마스크용으로 렌더.
func drawSilhouette(_ frame: Int) -> NSBitmapImageRep {
  let rep = newRep()
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let ctx = NSGraphicsContext.current!.cgContext
  ctx.clear(CGRect(x: 0, y: 0, width: W, height: H))
  NSColor.black.setFill()
  NSColor.black.setStroke()
  let phase = Double(frame) / Double(nFrames) * 2.0 * .pi
  func leg(hipX: Double, swing: Double) {
    let hipY = 15.0, len = 9.0
    let footX = hipX + sin(swing) * swingAmp
    let footY = hipY - len + max(0.0, cos(swing)) * 2.5
    let p = NSBezierPath()
    p.lineWidth = 3
    p.lineCapStyle = .round
    p.move(to: CGPoint(x: hipX, y: hipY))
    p.line(to: CGPoint(x: footX, y: footY))
    p.stroke()
  }
  leg(hipX: 20, swing: phase + .pi)
  leg(hipX: 24, swing: phase + .pi + 0.7)
  leg(hipX: 31, swing: phase)
  leg(hipX: 35, swing: phase + 0.7)
  NSBezierPath(roundedRect: CGRect(x: 14, y: 14, width: 24, height: 11),
    xRadius: 5.5, yRadius: 5.5).fill()
  let tail = NSBezierPath()
  tail.lineWidth = 3
  tail.lineCapStyle = .round
  tail.move(to: CGPoint(x: 15, y: 21))
  tail.line(to: CGPoint(x: 9, y: 27))
  tail.stroke()
  NSBezierPath(ovalIn: CGRect(x: 4, y: 24, width: 7, height: 7)).fill()
  NSBezierPath(roundedRect: CGRect(x: 33, y: 16, width: 8, height: 10),
    xRadius: 3, yRadius: 3).fill()
  NSBezierPath(ovalIn: CGRect(x: 35, y: 16, width: 12, height: 12)).fill()
  NSBezierPath(roundedRect: CGRect(x: 44, y: 17, width: 7, height: 5),
    xRadius: 2, yRadius: 2).fill()
  NSBezierPath(ovalIn: CGRect(x: 38, y: 26, width: 7, height: 6)).fill()
  NSBezierPath(ovalIn: CGRect(x: 34, y: 19, width: 6, height: 9)).fill()
  NSGraphicsContext.restoreGraphicsState()
  return rep
}

// 회색/바이올렛 밴드를 실루엣 모양으로 마스킹.
func renderFilled(_ sil: NSBitmapImageRep, fillPct: Int) -> NSBitmapImageRep {
  let out = newRep()
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
  let g = NSGraphicsContext.current!.cgContext
  g.clear(CGRect(x: 0, y: 0, width: W, height: H))
  // 1) 회색 전체
  gray.setFill()
  NSBezierPath(rect: CGRect(x: 0, y: 0, width: W, height: H)).fill()
  // 2) 바이올렛 아래 밴드(몸통 상하한 기준 fill%)
  let fillY = dogMinY + (dogMaxY - dogMinY) * Double(fillPct) / 100.0
  violet.setFill()
  NSBezierPath(rect: CGRect(x: 0, y: 0, width: W, height: fillY)).fill()
  // 3) 실루엣 알파로 마스킹(destinationIn: dest * srcAlpha)
  g.setBlendMode(.destinationIn)
  if let cg = sil.cgImage {
    g.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
  }
  NSGraphicsContext.restoreGraphicsState()
  return out
}

func writePng(_ rep: NSBitmapImageRep, _ path: String) {
  try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: path))
}

let outDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(
  atPath: outDir, withIntermediateDirectories: true)

var sils: [NSBitmapImageRep] = []
for f in 0..<nFrames { sils.append(drawSilhouette(f)) }
for f in 0..<nFrames {
  for lvl in fillLevels {
    writePng(renderFilled(sils[f], fillPct: lvl), "\(outDir)/run_\(f)_\(lvl).png")
  }
}

// 프리뷰: 라이트/다크 배경 위에 (상단) frame0 채움 0→100, (하단) 6프레임 @ 60%.
let scale = 4.0, gap = 10.0
let cols = 6.0
let cw = W * scale + gap
let sw = cw * cols + gap
let sh = (H * scale + gap) * 2 + gap
let sheet = newRepWH(Int(sw), Int(sh))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
// 좌 라이트 / 우 다크 배경.
NSColor(white: 0.93, alpha: 1).setFill()
NSBezierPath(rect: CGRect(x: 0, y: 0, width: sw/2, height: sh)).fill()
NSColor(white: 0.13, alpha: 1).setFill()
NSBezierPath(rect: CGRect(x: sw/2, y: 0, width: sw/2, height: sh)).fill()
NSGraphicsContext.current!.imageInterpolation = .high
let topLevels = [0, 20, 40, 60, 80, 100]
for (i, lvl) in topLevels.enumerated() {
  let r = renderFilled(sils[0], fillPct: lvl)
  let x = gap + Double(i) * cw
  r.draw(in: CGRect(x: x, y: sh - gap - H * scale, width: W * scale, height: H * scale))
}
for f in 0..<nFrames {
  let r = renderFilled(sils[f], fillPct: 60)
  let x = gap + Double(f) * cw
  r.draw(in: CGRect(x: x, y: gap, width: W * scale, height: H * scale))
}
NSGraphicsContext.restoreGraphicsState()
writePng(sheet, "\(outDir)/_sheet_fill.png")
print("wrote \(nFrames * fillLevels.count) matrix pngs + _sheet_fill.png to \(outDir)")

func newRepWH(_ w: Int, _ h: Int) -> NSBitmapImageRep {
  return NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}
