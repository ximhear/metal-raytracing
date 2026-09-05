# metal-raytracing

Metal Ray Tracing API 위에 올린 **해석적 CSG 레이 트레이서**. 메시가 아니라 수학식으로 부품을
교차시키고, 구간(interval) 불리언 연산으로 합집합/교집합/차집합을 평가한다. iOS · macOS 공용.

전체 설계는 `README.md` 를 본다.

## 프로젝트 규칙

- **`RayTracer.xcodeproj` 는 생성물이다.** 원본은 `project.yml` (XcodeGen).
  파일을 추가/삭제하면 `make project`. Xcode 에서 직접 추가한 파일은 다음 생성 때 사라진다.
- 서명 팀은 `Local.xcconfig` 에 있다 (`make team`). **`DEVELOPMENT_TEAM` 을 `project.yml` 로
  옮기지 말 것** — pbxproj 설정이 xcconfig 를 이겨서 재생성 때마다 초기화된다.
- `ShaderTypes.h` 의 enum 값과 `CSG.swift` 의 `PartKind` rawValue 는 **항상 같이 바꾼다.**
  둘이 어긋나면 컴파일은 되고 형상만 조용히 틀린다.
- 씬 클래스 이름은 `Scene` 이 아니라 `CSGScene` 이다 — `SwiftUI.Scene` 과 겹치면
  `RayTracerApp` 이 `App` 을 만족하지 못한다는 엉뚱한 에러가 난다.
- **빌드 성공은 검증이 아니다.** 셰이더를 건드렸으면 `make snapshot` 후
  `out/frame.png` 를 Read 로 열어 눈으로 확인한다.
- `MTL_LANGUAGE_REVISION` 은 배포 타깃에 맞춰 `Metal30` 으로 고정돼 있다. 이걸 올리면
  그보다 낮은 OS 기기에서 `makeDefaultLibrary()` 가 nil 이 되고 **흰 화면**이 된다.
- **intersection function 의 스레드 스택은 A15 급 기기에서 병목이다.** `ShaderTypes.h` 의
  `CSG_MAX_INTERVALS`/`CSG_MAX_STACK` 을 키우거나 `Interval`/`Hit` 을 `float3` 로 되돌리면
  `Compute pipeline exceeds available stack space` 로 실기기에서만 실패한다 — **M 시리즈 Mac 에서는 재현되지 않는다.**
- `CSG.unionAll` 은 **왼쪽 체인**으로 묶는다 (스택 깊이 2 고정). 균형 트리가 더 낫다고 바꾸지 말 것 — 후위 표기 평가에서는 반대다.
- 씬은 `CSGScene(.bus)` / `.showcase` 두 개다 (`Renderer.init` 에서 고름).
  **이 저장소는 git 이 아니다** — 씬이나 모델 코드를 지우면 되돌릴 수 없으니, 지우는 대신 Kind 를 늘린다.
- 씬을 만들 때 `Bus.interiorViolations` / `floatingViolations` 가 돌면서 부품이 둥근 차체를
  뚫고 나가거나 허공에 뜨는지 검사한다. **콘솔에 `⚠️ Bus:` 가 찍히면 무시하지 말 것** —
  이 종류는 특정 각도에서만 보여서 눈으로는 놓친다.
- **덩어리를 둥글릴 때는 `CSG.roundBox`** (상자 ⊕ 구). 둥근 윤곽 세 개를 교차하는 방식은
  꼭짓점에 능선이 남는다 — `smooth-surfaces` 스킬에 이유와 대안을 정리해 뒀다.
- **사실감은 셰이딩에서 온다.** `Material.gloss`(프레넬 환경 반사) 와 `grain`(표면 얼룩) 이
  0 이면 형상이 정확해도 점토처럼 보인다. 큰 면은 아주 살짝이라도 곡률을 줘야 빛이 흐른다.
- 초기화 실패는 절대 조용히 삼키지 않는다. `Renderer` 는 `RendererError` 를 던지고
  `ContentView` 가 원인과 GPU 진단을 화면에 띄운다. 새 실패 지점을 만들면 같은 규칙을 따른다.

## 스킬

| 스킬 | 언제 |
|---|---|
| `raytracer-build` | 빌드 · 실행 · 스냅샷 · 빌드 에러 진단 |
| `csg-part` | 새 해석적 부품(도형) 추가 |
| `csg-scene` | 오브젝트 조립 · 재질 · 배치 · 성능 튜닝 |
| `smooth-surfaces` | 라운드·필렛·법선 연속성. "둥근데 부자연스럽다" 일 때 |
