---
name: raytracer-build
description: Build, run, and visually verify the Metal CSG ray tracer in this repo. Use whenever the task is to compile, launch, screenshot, or debug the RayTracer app on macOS or iOS — including "does it still build", "show me the render", "왜 안 그려져", regenerating the Xcode project after adding files, or diagnosing Metal/acceleration-structure runtime failures.
---

# RayTracer 빌드 · 실행 · 검증

## 프로젝트 구조

`RayTracer.xcodeproj` 는 **생성물**이다. 원본은 `project.yml` (XcodeGen).
소스 파일을 추가/삭제했으면 반드시 `make project` 로 재생성한다 — Xcode 에서 직접 파일을 추가하면 다음 생성 때 날아간다.

| 파일 | 역할 |
|---|---|
| `project.yml` | XcodeGen 정의. 타깃 `RayTracer-iOS`, `RayTracer-macOS` 두 개 |
| `Local.xcconfig` | 머신마다 다른 서명 설정. **생성물이 아니라서 재생성해도 살아남는다** |
| `RayTracer/*.swift` | 앱 · 렌더러 · CSG DSL · 씬 |
| `RayTracer/Shaders.metal` | intersection function + 렌더 커널 |
| `RayTracer/ShaderTypes.h` | Swift ↔ Metal 공유 구조체. 브리징 헤더로 양쪽에서 import |

## 표준 루프

```bash
make mac        # macOS 빌드
make ios        # iOS 빌드 (서명 없이 컴파일만 검증)
make snapshot   # 오프스크린 한 프레임 → out/frame.png
```

`make snapshot` 후에는 **반드시 Read 툴로 `out/frame.png` 를 열어 눈으로 확인**한다.
"빌드 성공"은 셰이더가 옳다는 증거가 아니다 — CSG 평가가 틀리면 조용히 빈 화면이나 깨진 형상이 나온다.

씬은 `SCENE=` 으로 고른다 (기본 `bus`). **코드를 고칠 필요가 없다** — 예전에 `Renderer` 의
`CSGScene(...)` 을 sed 로 바꿔 가며 찍던 방식은 소스를 깨뜨린 적이 있다:

```bash
make snapshot SCENE=showcase OUT=out/showcase.png     # bus / showcase / roundBoxTest
```

시작 메뉴 레이아웃은 앱의 `--menu-shot <경로>` 로 확인한다.
`ImageRenderer` 는 `ScrollView`/`NavigationStack` 안을 레이아웃하지 않으므로
메뉴 **부품(MenuHeader + SceneCard)** 을 같은 배치로 다시 그려 찍는다.

카메라 각도를 바꿔 보려면 `T` (초) 를 준다. 카메라는 `t` 에 따라 궤도 회전한다:

```bash
make snapshot T=1.5 W=1200 H=750 OUT=out/side.png
```

궤도 카메라는 항상 원점을 보므로, 구석에 놓인 오브젝트를 검수하려면 카메라를 직접 놓는다:

```bash
make snapshot EYE=-5.0,0.4,-0.2 LOOK=-0.5,-1.4,-4.2 OUT=out/bus.png
```

**창 크기를 바꾸면 잠깐 비율이 틀어져 보인다**
요청 시 렌더링이라 리사이즈 중에는 새 프레임이 안 나오는데, CAMetalLayer 가 직전 프레임 텍스처를
새 창 크기에 **늘여서** 보여 주기 때문이다 (렌더 자체는 항상 텍스처 크기로 aspect 를 계산하므로 정상).
`ScaledMTKView.updateDrawableSize()` 가 크기 변경 시 `requestRedraw()` 가 아니라
**`draw()` 를 즉시 호출**해서 해결한다. macOS 는 `inLiveResize` 동안 해상도를 더 낮춰 드래그를 부드럽게 한다.

앱에서는 **카메라가 수동**이다 — 드래그로 회전, 스크롤/핀치로 확대, 더블클릭(두 번 탭)으로 초기화.
자동 회전이 아니므로 `isPaused` + `enableSetNeedsDisplay` 로 **요청이 있을 때만** 렌더링한다.
카메라나 크기를 바꾸는 코드는 반드시 `ScaledMTKView.requestRedraw()` 를 불러야 하고,
**부르지 않으면 화면이 그대로 멈춰 있다** (첫 프레임을 놓치면 어두운 보라 배경만 남는다).
우하단 저장 버튼은 현재 카메라로 긴 변 2400 px 를 다시 렌더링해 macOS 는 저장 패널,
iOS 는 사진 앱에 넣는다 (`ImageExport`).

`make run` 은 창을 띄운다. 화면 캡처 권한이 없는 환경에서는 `screencapture` 가
`could not create image from display` 로 실패하므로, 시각 확인은 `make snapshot` 을 쓴다.

## 자주 겪는 함정

**`type 'RayTracerApp' does not conform to protocol 'App'`**
십중팔구 진짜 원인이 아니다. `some Scene` 이 `SwiftUI.Scene` 대신 프로젝트 안의 다른 `Scene` 타입으로
해석됐거나(그래서 씬 클래스 이름이 `CSGScene` 이다), `ContentView` 쪽 타입 에러가 이 한 줄로 뭉개진 것이다.
`RayTracerApp.swift` 를 빼고 나머지만 타입 체크해서 진짜 에러를 찾는다:

```bash
swiftc -typecheck -parse-as-library -sdk $(xcrun --sdk macosx --show-sdk-path) \
  -target arm64-apple-macos13.0 -import-objc-header RayTracer/RayTracer-Bridging-Header.h \
  RayTracer/ContentView.swift RayTracer/MetalView.swift RayTracer/Renderer.swift \
  RayTracer/Scene.swift RayTracer/CSG.swift
```

**`unexpected service error: The Xcode build system has crashed`**
십중팔구 소스가 깨졌다. 특히 **한글 주석을 sed 로 자르면** UTF-8 이 중간에서 끊겨
빌드 시스템이 죽는다. 다시 빌드해도 같은 에러면 `swiftc -typecheck` 로 진짜 원인을 찾는다
(위의 `App` 가짜 에러 항목과 같은 방법). 소스 편집은 sed 보다 python 치환이 안전하다.

**`xcodebuild` 출력이 너무 길다**
`| grep -E "error:|BUILD" | sort -u` 로 거른다.

**흰 화면만 나온다 (특히 실기기)**
앱이 원인을 스스로 알려 준다. `Renderer.init(device:)` 는 `RendererError` 를 던지고
`ContentView` 가 그 메시지 + GPU 진단(이름 / raytracing / functionPointers / family / OS 버전)을
화면에 띄운다. 렌더링이 시작되면 좌하단 HUD 에 `해상도 · fps · GPU 이름` 이 뜬다.

- **에러 화면이 뜬다** → 메시지가 그대로 원인이다
- **HUD 는 뜨는데 화면이 흰색** → 커널은 도는데 셰이딩이 틀린 것. `make snapshot` 으로 같은 씬을 뽑아 비교
- **HUD 도 에러도 없이 어두운 보라색** → `present` 가 한 번도 안 됐다. `MetalView` 의 배경색이 그 색이다
- **완전한 흰색에 아무것도 없다** → 앱이 이 버전이 아니다. 다시 빌드해서 설치

`MTL_LANGUAGE_REVISION` 이 **기기 OS 버전보다 높으면** `makeDefaultLibrary()` 가 nil 을 돌려주고
정확히 흰 화면이 된다. Metal 3.1 은 iOS 17 / macOS 14 이상 전용이다.
`project.yml` 은 배포 타깃(iOS 16 / macOS 13)에 맞춰 `Metal30` 으로 고정해 두었다 — 올릴 때는
`options.deploymentTarget` 도 같이 올린다. 실제로 적용된 값은 빌드 로그에서 확인한다:

```bash
rm -rf build && make ios 2>&1 | grep -oE '\-std=metal[0-9.]+|\-target air64[^ ]+'
```

**콘솔 로그**
`RendererStore` 가 진단과 실패 원인을 `print` 한다. Xcode 에서 Run 하면 콘솔에 바로 보이고,
기기에서 직접 실행했다면 Console.app 또는 `xcrun devicectl` 로 본다.

**헤드리스로 초기화만 검증**
```bash
build/Build/Products/Debug/RayTracer-macOS.app/Contents/MacOS/RayTracer-macOS --snapshot /tmp/x.png
```
실패하면 원인을 stderr 에 찍고 exit 1 한다. 단 macOS 경로라서 iOS 전용 문제는 잡히지 않는다.

**`Compute pipeline exceeds available stack space` (실기기 전용)**
intersection function 의 스레드 스택이 GPU 한도를 넘었다. **macOS/M 시리즈는 한도가 커서 통과하므로
`make mac` 으로는 절대 재현되지 않는다** — A15 급 기기에서만 터진다.
지배 요인은 `ShaderTypes.h` 의 `CSG_MAX_INTERVALS` × `CSG_MAX_STACK` 이고,
`Shaders.metal` 의 `Interval`(36B) · `Hit`(16B) 크기가 계수다. 줄이는 순서:

1. `CSG_MAX_STACK` 을 낮춘다 — `Renderer` 가 `CSG.stackDepth()` 로 검증하므로 안전하게 내릴 수 있다
2. `CSG_MAX_INTERVALS` 를 낮춘다 (형상이 뭉개질 수 있으니 스냅샷으로 확인)
3. 새 지역 변수로 `IntervalList` 를 만들지 않는다 — `evalCSG` 는 스택 슬롯에 직접 쓰고
   연산 결과는 `result` 를 임시로 재사용한다. 사본 하나가 220B다

`Interval`/`Hit` 은 `static_assert` 로 크기가 고정돼 있다. `packed_float3` 를 `float3` 로 되돌리면
16바이트 정렬 때문에 구조체가 64B/32B 로 부풀어 컴파일이 막힌다 — 그 assert 를 지우지 말 것.

구조체 크기를 직접 재려면:
```bash
xcrun -sdk macosx metal -std=metal3.0 -I RayTracer -c /tmp/size.metal -o /dev/null
```
에 `template <int N> struct Show { static_assert(N < 0, "size"); };` 를 써서 에러 메시지로 뽑는다.

**시뮬레이터**
Metal Ray Tracing 은 시뮬레이터에서 동작하지 않는다. iOS 는 A13 이상 실기기 전용이고,
CI/로컬 검증은 macOS 타깃으로 한다.

**서명 / 실기기 배포**
팀 ID 는 `project.yml` 이 아니라 **`Local.xcconfig`** 에 있다 (`.gitignore` 됨, 템플릿은 `Local.xcconfig.example`).
`project.yml` 의 `configFiles` 가 이걸 프로젝트 baseConfiguration 으로 연결한다.

```bash
make team                    # 현재 값 + 이 Mac 의 팀 ID 목록 (scripts/dev-teams.sh)
make team TEAM=XXXXXXXXXX    # 설정 + 재생성
```

**`DEVELOPMENT_TEAM` 을 `project.yml` 의 `settings` 로 되돌리지 말 것.** pbxproj 의 빌드 설정은
xcconfig 보다 우선하므로 xcconfig 값이 통째로 무시되고, 재생성할 때마다 팀이 초기화된다.
같은 이유로 Xcode UI 의 Signing & Capabilities 에서 고른 팀도 재생성 때 날아간다 — 사용자에게
`make team` 을 쓰라고 안내한다.

인증서 괄호 안의 값은 팀 ID 가 아니라 개인 ID 다. 팀 ID 는 인증서 Subject 의 `OU` 필드이고
`scripts/dev-teams.sh` 가 그걸 뽑아 준다.
