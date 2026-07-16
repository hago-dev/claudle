---
name: app-perf
description: Claudle 성능 점검 — 상시구동 트레이 앱 특성(워처 부하, DB 쓰기, 폴링). $ARGUMENTS로 대상.
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Read
  - Glob
  - Grep
---

# app-perf

`$ARGUMENTS`로 대상을 받아 성능을 점검한다. 일반 모바일 앱과 달리 이 앱은 **상시 백그라운드 구동**(메뉴바/HUD)이 핵심 특성 — 프레임률보다 장시간 실행 시 리소스 누적이 더 중요하다.

## 검사 항목

### 로그 워처 (`watcher` 패키지, `data/providers/claude_code` + `data/ingest`)
- 파일시스템 이벤트 폭주 시(Claude Code가 세션을 대량 갱신) 이벤트마다 즉시 파싱하지 않는지 — 실제 방어 지점은 provider의 400ms 디바운스 + dirty set(`claude_code_provider.dart:19`의 `_dirty`, `:55-57`의 `_debounce`, `:60-70`의 `_flush()`). 폭주분이 한 번의 `_flush()`로 합쳐지는지 확인.
- 증분 파싱(커서 기반)은 provider가 아니라 `data/ingest/ingest_service.dart:103-148`에 있다(`db.getCursor`/`db.putCursor` + `usage_database.dart`의 `file_cursor` 테이블 → `startOffset = cursor.byteOffset`로 추가분만 읽음). provider는 소스 발견 + 실시간 감시만 하고 파싱/커서/디덤은 `IngestService`에 위임(`claude_code_provider.dart:13` 주석).
- 워처 구독이 `ClaudeCodeUsageProvider._subs`(`claude_code_provider.dart:18` 선언, `:47` 등록)에 등록돼 `ClaudeCodeUsageProvider.dispose()`(`:73-79`)에서 정리되는지(구독 누수 → 메모리/파일핸들 누적). ※ `AppController._subs`(`app_controller.dart:55`)는 이름만 같을 뿐 `provider.watch()` 파생 신호 스트림(`:98`)용이다 — 워처 구독 누수를 여기서 찾지 말 것.

### DB 쓰기 (`core/db/usage_database.dart`, sqlite3)
- 이벤트 단위 INSERT를 배치 없이 반복 호출하는지(대량 백필 시 트랜잭션 배칭 여부 확인).
- DB 커넥션이 앱 생애주기 동안 하나로 유지되는지(매번 open/close하지 않는지).

### 폴링 (`app_controller.dart` → `LimitsController`, 60s 주입)
- 실제 간격은 `app_controller.dart:37-41`에서 `LimitsController(RealLimitsSource(), interval: const Duration(seconds: 60))`으로 주입 — 주석에 "내부 API 보호"로 명시된 의도적 하한. 60s를 낮추는 변경 금지.
- `limits_controller.dart`의 기본값 30s는 주입이 없을 때만 적용.

### UI 리빌드 (`AnimatedBuilder` + `Listenable.merge`)
- 값이 실제로 바뀌지 않았는데 `revision.value++` 등으로 불필요하게 전체 대시보드를 리빌드하지 않는지 — revision/총계 리빌드는 `dashboard.dart:206-208`의 `AnimatedBuilder(animation: Listenable.merge([controller.totalsAll, controller.revision]))`가 담당(같은 파일 `:150` 주석: "총계 변화·revision(별칭)엔 `AnimatedBuilder`, 기간 선택엔 `setState` 로 리빌드").
- `dashboard.dart`/`agents_screen.dart`의 다수 private 위젯 분해가 리빌드 범위를 좁히는 데 기여하는지(범위가 넓은 `AnimatedBuilder`/`Listenable.merge`가 새로 생기면 회귀). 참고로 `ValueListenableBuilder`는 `dashboard.dart` 3곳(`:31` status, `:46`·`:109` limits)뿐이고 revision과 무관하다 — `agents_screen.dart`는 `setState` + `AnimatedBuilder(Listenable.merge([_clock, _legs]))`(`:550-551`) + `FutureBuilder`(`:965`)로 리빌드한다.

## 프로파일링
```bash
fvm flutter run --profile -d macos     # 또는 -d windows
```
DevTools의 Memory/Performance 탭으로 장시간 구동 시 메모리 상승 곡선 확인(짧은 프로파일링으로는 누수 특성이 잘 안 보임 — 최소 수십 분 관찰 권장).
