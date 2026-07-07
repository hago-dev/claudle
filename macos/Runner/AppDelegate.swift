import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // 메뉴바 전용 앱: 창을 숨겨도(마지막 창이 닫혀도) 종료되지 않아야 함.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
