# ReadTap Reader 모듈 재설계 설계도 (기능 보존형, 단계별 실행)

버전: 2026-02-17 (요청 기반 초안)

목표:  
- 기존 기능(상단/하단 바 토글, long press lookup, 탭으로 popup dismiss/토글, 썸네일 패널, OCR 연계, 번역 후보 선택, 캐시/DB 처리)을 모두 유지
- `PDFKitView.Coordinator`의 제스처 상태 결합을 해체해 **"문턱에서 멈춤", "Gesture gate timed out", reopen 시 탭/롱프레스 정지**를 근본적으로 줄임
- 안정성 우선(동작 보존) + 이후 성능 개선은 독립적으로 진행

---

## 0. 현재 상태 설계의 핵심 병목(원인 정리)
현재 한 파일/한 구조(`PDFKitView.Coordinator`)가 한 번에 처리하고 있음
- PDF 렌더/문서 로드/페이지 이동
- 제스처 enable/disable 상태기계
- selection → lookup → popup 흐름
- 캐시 상태 동기화 / 타이머 스케줄링

이로 인해 다음이 생김:
1. `singleTap`이 lookup 로직/동기화 조건에서 막혀 사용자 탭이 통과되지 않음
2. reopen/재활성 시 `needsGestureReactivation` 경로에서 gesture delegate 재수립 race
3. top/bottom 바와 thumbnail panel의 표시 상태가 여러 경로에서 중복 변경되어 freeze/딜레이 체감
4. long press/lookup/gesture가 서로 강하게 얽혀 상태 전이가 불명확

---

## 1) 새 구조: 3계층 + 1개 상태엔진

### 1-1. 제안 아키텍처
1. `ReaderShell` (SwiftUI)
   - 화면 구성 책임: PDFCanvas + 바/팝업/썸네일 패널/오버레이
   - UI 상태만 갖고, 비즈니스 상태를 직접 만지지 않음

2. `ReaderInteractionEngine` (신규 FSM)
   - 이벤트를 받아 상태 전이만 계산  
   - single tap / long press / two finger / pan / pinch 를 **경로별로 분기**
   - “현재 유효 제스처”를 명확히 판단해 PDFKit delegate는 가급적 단순하게 유지

3. `ReaderDocumentGateway`
   - PDF document open / close / page 이동 / 줌 / bounds warmup / thumbnail prefetch 트리거 관리
   - 캐시 계층(PDFDocumentCache, ThumbnailCache, OCR cache, 후보 캐시)와의 인터페이스만 담당

4. `ReaderLookupPipeline`
   - 선택 텍스트 처리, long press lookup 실행, 번역 후보 조회, popup 모델 갱신
   - 실패/재시도/중복요청/취소 정책 분리

5. `ReaderPanelController`
- top/bottom chrome, 썸네일 패널, popup 상태의 단일 진입점
- "UI 토글은 오직 이벤트에 의해 변경" 규칙 적용

### 1-2. 데이터흐름(단방향)
UI 제스처  
→ `ReaderInteractionEngine`  
→ (명령) `ReaderDocumentGateway` / `ReaderLookupPipeline`  
→ 결과 이벤트  
→ `ReaderShell` 상태 갱신  

핵심 원칙:
- `PDFKitView`는 **입출력 바인딩 + 제스처 delegate 브릿지** 역할만 담당
- 동기화/딜레이 판단은 엔진이 단일 책임으로 수행

---

## 2) 단계별 실행 계획 (한 번에 하나씩)

아래는 실제로 “따라가면서 작업”하기 위한 순서입니다.

### Phase 1 — 계약(Protocol) 먼저 분리 (무리한 리라이트 금지)
목표: 기존 동작을 깨지 않으면서 새 엔진과 기존 뷰모델 간 인터페이스 고정

#### 1) 새 파일 추가
- `readtap/ReaderInteractionContracts.swift`  
  - 이벤트/명령/상태 구조체 정의

추가 타입 예시
- `ReaderEvent`
  - `.viewAppeared`, `.viewDisappeared`
  - `.pdfDocumentBound`, `.pdfLoadSuccess`, `.pdfLoadFail`
  - `.gestureTap`, `.gestureLongPressBegan/Changed/Ended`, `.gestureTwoFingerTap`, `.gesturePan`, `.gesturePinch`
  - `.lookupResultReceived`, `.lookupFailed`, `.popupDismissed`
  - `.chromeToggleRequested`, `.thumbnailPanelToggled`
  - `.pageChanged`, `.zoomRatioChanged`
- `ReaderCommand`
  - `.applyDocument`, `.setGesturePolicy`, `.showPopup`, `.hidePopup`, `.hideLookupArtifacts`
  - `.startLookupLookup`, `.cancelLookup`, `.syncChromeVisibility`
- `ReaderUIState`
  - `isChromeVisible`, `isPopupVisible`, `isThumbnailPanelVisible`, `isLookupActive` 등 최소 필드

#### 2) 기존 코드 보존 포인트 매핑
- `ReaderViewModel.handleSingleTap()` -> `ReaderEvent.chromeToggleRequested` 또는 `dismissPopup` 맵핑
- `onSelection` 콜백 -> `ReaderEvent.selectionReady`
- `onLookupTapOutside` -> `ReaderEvent.popupDismissTapped`

#### 성공 기준
- `ReaderInteractionContracts.swift` 컴파일 통과
- 기존 코드의 최소 변경으로 참조 가능(아직 동작 변경 없음)

---

### Phase 2 — 현재 동작을 감싸는 “상태머신” 추가
목표: 제스처/상태 결정 규칙을 중앙화, 일단 사용 안 하고 로그만 확인

#### 1) 새 파일 추가
- `readtap/ReaderInteractionEngine.swift`
- 핵심 클래스/구조체:
  - `final class ReaderInteractionEngine`
  - `func reduce(_ state: inout ReaderUIState, event: ReaderEvent) -> [ReaderCommand]`
  - `func shouldHandleTap() -> Bool`
  - `func shouldHandleLookup() -> Bool`
  - `func onDocumentBound()`, `onDocumentUnbound()`

#### 2) 상태 설계
- 상태 enum:  
  - `.coldStart`  
  - `.loadingDocument`  
  - `.readyInteractive`  
  - `.lookupActive`  
  - `.popupOpen`  
  - `.suspended`  

#### 3) 규칙(우선순위)
1순위: 앱 생명주기/문서 로드 안정성  
2순위: popup dismiss/close  
3순위: chrome 토글(singe tap)  
4순위: lookup(long press/selection)  
5순위: navigation

#### 4) 테스트
- 이벤트 시뮬레이터를 따로 만들지 않고, 로그로만 상태 전이 검증  
  - `phase`, `incoming event`, `emitted command`, `next state`

#### 성공 기준
- 기존 코드에서 engine는 사용되지 않아도 compile 유지

---

### Phase 3 — `PDFKitView.Coordinator`를 브리지로 축소
목표: delegate 메서드에서 분기 처리 제거, 상태엔진 호출만 수행

#### 1) 현재 `Coordinator` 분리
- `PDFKitView.swift` 내 역할을 아래로 제한:
  - Gesture recognizer 등록/해제
  - delegate 진입점에서 `ReaderEvent` 생성
  - 엔진에서 온 `ReaderCommand` 적용(gesture enable/disable, lookup 실행 호출)

#### 2) 제거/단순화 대상
- `shouldReceive`에서 복잡 조건 다수 삭제
- `canHandleSingleTapGesture`, `canHandleLookupPressGesture`, `reactivateGesturesAfterReopen`의 직접 제어를 점진적으로 엔진으로 이동
- `singleTapReenableWorkItem`/`suppressSingleTap` 중 “UI 토글 막는 임시 억제”는 엔진 명령 기반으로 통합

#### 3) 단계적 적용
- 먼저 `singleTap`과 `lookupPress`만 엔진에 연결
- `twoFinger`/`dismissPan`은 기존 유지(후행)

#### 성공 기준
- `System gesture gate timed out` 로그가 감소
- reopen 직후 첫 탭이 chrome toggle로 동작
- long press on/off 후 single tap fallback 가능

---

### Phase 4 — Lookup 파이프라인 분리
목표: long press lookup 실패/재시도/팝업 갱신을 독립 모듈로 이동

#### 1) 새 파일 추가
- `readtap/ReaderLookupPipeline.swift`

역할:
- selection normalization
- `performLookup(at:)` 트리거
- `ContextMeaningService` 호출 결과 매핑
- 후보 캐시/잘못된 뜻 신고 플래그 전달

#### 2) 이동할 기능
- `handleLookupLongPress` 내부 로직 일부
- selection signature, probe key, lookup cooldown, fallback 재시도 상태
- popup 표시/업데이트 트리거 분리

#### 3) API 계약
- 입력: PDFView + 위치 + 제스처 시점
- 출력: `lookupCandidates`, `selectionInfo`, `isLookupHandled`, `didSelectFallback`

#### 성공 기준
- lookup 실행/팝업 표시 품질 변화 없음
- long press로 popup 호출 시 앱 freeze 없음
- lookup 실패 케이스별 경로가 로그로 구분됨

---

### Phase 5 — 썸네일/패널/DB 캐시 경로를 게이트 분리
목표: 패널 토글/썸네일 warmup가 chrome gesture와 결합되지 않도록 분리

#### 1) `ReaderPanelController` 추가
- `readtap/ReaderPanelController.swift`
- 패널 상태(open/close, width, preview generation) 단일 관리

#### 2) 이벤트 연결
- `thumbnailPanelToggled`, `didTapOnTop`, `didTapOnBottom`, `readerIdle` 이벤트만 처리
- 썸네일 미리보기/DB warmup는 문서 준비 완료 후 백그라운드 큐에서 상태 이벤트 발행

#### 3) DB/캐시 인터페이스 정리
- 패널 입출력은 `ReaderDocumentGateway` 경유
- 페이지별 캐시 로딩 실패시 fallback 동작은 동일하되 사용자 탭 동작엔 영향 없게

#### 성공 기준
- 열었다 닫았다할 때 top/bottom 바 표시/비표시 안정
- 썸네일 패널이 lazy load로 동작해 첫탭 지연 감소

---

### Phase 6 — 성능 안전장치 + 회귀 방지
목표: 현재 병목 개선을 구조 개선으로 고정

#### 1) 작업 큐 일원화
- 모든 UI바인딩 동기화는 `enqueueReaderStateUpdate` 같은 기존 패턴으로 메인 큐 통합
- background 작업에서 `@Published` 직접 변경 금지

#### 2) 디바운스 규칙 고정
- single tap debounce (0.12~0.25s)
- lookup retry cooldown
- page/scale 변경 동기화 throttle

#### 3) 타임아웃/로그
- 제스처 타임아웃, lookup timeout, prefetch timeout 각각 1개씩만 남기고 중복 제거
- 로그 태그 정규화: `ReaderGesture`, `ReaderLookup`, `ReaderChrome`, `ReaderDocument`

#### 4) 회귀 체크리스트(수동)
- PDF 열기 직후 single tap 1회: 상하단 바 토글
- long press on/off 반복: 첫/둘째 탭 모두 동작
- open/close 반복 5회: top/bottom 바가 유지되며 freeze 없음
- zoom+slide 다음 페이지 전환 시 zoom 유지 정책 확인

---

## 3) 파일 스펙 (최종 안)

### 새로 추가할 파일
- `readtap/ReaderInteractionContracts.swift`
- `readtap/ReaderInteractionEngine.swift`
- `readtap/ReaderInteractionStateMachine.swift` (엔진 내부 더 크면 분리)
- `readtap/ReaderDocumentGateway.swift`
- `readtap/ReaderLookupPipeline.swift`
- `readtap/ReaderPanelController.swift`

### 변경 대상 파일
- `readtap/PDFKitView.swift`
- `readtap/ContentView.swift`
- `readtap/ReaderViewModel.swift`
- `readtap/ReaderThumbnailSidebar.swift`(패널 이벤트 진입점 정비 시)
- `readtap/Database/*`(캐시/메타 쪽 계약 유지 시 점진 반영)

---

## 4) 구현 순서(실행 순번)
1. **Phase 1**: 계약/타입 먼저 (코드가 안 깨지는지 확인)
2. **Phase 2**: 엔진 구현 + 단위 이벤트 시뮬레이션 로그 확인
3. **Phase 3**: `PDFKitView` delegate 브릿지화(가장 핵심)
4. **Phase 4**: lookup 파이프라인 이관
5. **Phase 5**: 썸네일/패널 게이트 분리
6. **Phase 6**: 성능/안정성 정리(로그/쿨다운/타입 안정화)

매 단계마다 사용자 시나리오 4개 실행:
- a) 앱 실행→PDF 오픈→single tap
- b) PDF 오픈→롱프레스 lookup
- c) open/close 반복
- d) zoom+page 이동

---

## 5) 실패 시 롤백 규칙
- 한 단계에서 재현 불가 버그가 생기면 해당 단계 변경분만 되돌림
- `ReaderInteractionContracts`와 `ReaderInteractionEngine`은 유지한 채 `PDFKitView`를 기존 delegate 경로로 되돌리는 브리지만 복원 가능
- 각 단계별로 `git commit` 단위를 나눠서 진행해 롤백 포인트 확보

---

## 6) 다음 작업 제안 (이번 요청에서 바로 시작 가능)
- 지금은 **Phase 1 문서/타입 설계**까지만 적용하고, 다음 메시지에서
  1) `ReaderInteractionContracts.swift` 생성,
  2) `ReaderInteractionEngine.swift` 골격 추가,
  3) `PDFKitView`에서 이벤트 emit 포인트를 1개만 연결
  순으로 바로 코드 변경 들어가겠습니다.

