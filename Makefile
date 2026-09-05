# RayTracer — XcodeGen 기반 빌드/실행 헬퍼
#
#   make project      project.yml → RayTracer.xcodeproj 재생성
#   make mac          macOS 앱 빌드
#   make ios          iOS 앱 빌드 (서명 없이 컴파일 검증)
#   make run          macOS 앱 실행 (창 띄움)
#   make snapshot     오프스크린 한 프레임 → out/frame.png
#   make gallery      README 갤러리 이미지 전부 다시 렌더 (docs/images)
#   make open         Xcode 로 열기
#   make clean

PROJECT   := RayTracer.xcodeproj
# 서명 설정. 생성물이 아니라서 make project 에도 살아남는다
XCCONFIG  := Local.xcconfig
DD        := build
MAC_APP   := $(DD)/Build/Products/Debug/RayTracer-macOS.app
MAC_BIN   := $(MAC_APP)/Contents/MacOS/RayTracer-macOS

# snapshot 파라미터
OUT       ?= out/frame.png
W         ?= 900
H         ?= 560
T         ?= 0.0
SCENE     ?= bus
# 카메라 직접 지정 (모델 검수용). 예: make snapshot EYE=-6,0,-1 LOOK=-0.5,-1.4,-4.2
EYE       ?=
LOOK      ?=
CAM       := $(if $(EYE),--eye $(EYE)) $(if $(LOOK),--look $(LOOK)) --scene $(SCENE)

.PHONY: project mac ios run snapshot open clean team gallery

$(XCCONFIG):
	@cp $(XCCONFIG).example $@
	@echo "$(XCCONFIG) 를 만들었습니다. 실기기 빌드를 하려면 'make team' 으로 팀을 설정하세요."

project: $(XCCONFIG)
	xcodegen generate

$(PROJECT): project.yml $(XCCONFIG)
	xcodegen generate

## 서명 팀 확인/설정 — Xcode UI 대신 여기서 바꿔야 재생성해도 유지된다
team: $(XCCONFIG)
	@if [ -n "$(TEAM)" ]; then \
		sed -i '' "s|^DEVELOPMENT_TEAM *=.*|DEVELOPMENT_TEAM = $(TEAM)|" $(XCCONFIG); \
		echo "설정됨 → $(XCCONFIG): DEVELOPMENT_TEAM = $(TEAM)"; \
		$(MAKE) --no-print-directory project; \
	else \
		echo "현재 값 ($(XCCONFIG)):"; \
		grep -E '^(DEVELOPMENT_TEAM|BUNDLE_ID_PREFIX)' $(XCCONFIG) | sed 's/^/  /'; \
		echo ""; \
		echo "이 Mac 에서 쓸 수 있는 팀:"; \
		./scripts/dev-teams.sh; \
		echo ""; \
		echo "바꾸려면:  make team TEAM=XXXXXXXXXX"; \
	fi

mac: $(PROJECT)
	xcodebuild -project $(PROJECT) -scheme RayTracer-macOS -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath $(DD) build

ios: $(PROJECT)
	xcodebuild -project $(PROJECT) -scheme RayTracer-iOS -configuration Debug \
		-destination 'generic/platform=iOS' -derivedDataPath $(DD) \
		CODE_SIGNING_ALLOWED=NO build

run: mac
	open $(MAC_APP)

snapshot: mac
	@mkdir -p $(dir $(OUT))
	$(MAC_BIN) --snapshot $(OUT) $(W) $(H) $(T) $(CAM)

open: $(PROJECT)
	open $(PROJECT)

clean:
	rm -rf $(DD) out

gallery: mac
	@scripts/gallery.sh
