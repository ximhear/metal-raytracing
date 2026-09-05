#!/bin/zsh
# README 갤러리 이미지를 다시 뽑는다: 씬마다 2배로 렌더한 뒤 축소 (슈퍼샘플링).
# 사용: make gallery   (macOS 앱이 먼저 빌드돼 있어야 한다)
set -e
cd "$(dirname "$0")/.."
BIN=build/Build/Products/Debug/RayTracer-macOS.app/Contents/MacOS/RayTracer-macOS
mkdir -p docs/images
render() {  # 이름 씬 가로 세로 궤도시각 [추가 인자...]
  local name=$1 sc=$2 w=$3 h=$4 t=$5; shift 5
  "$BIN" --snapshot /tmp/gallery.png $((w*2)) $((h*2)) "$t" --scene "$sc" "$@" >/dev/null
  sips -z "$h" "$w" /tmp/gallery.png --out "docs/images/$name.png" >/dev/null
  echo "  docs/images/$name.png"
}
render bus bus 1200 750 2.3
render bus-glass glassBus 1200 750 2.3
render bus-tinted tintedGlassBus 1200 750 2.3
render watch watch 1200 750 0.0
render turbofan turbofan 1200 750 0.0 --eye -22,11,28 --look 3,-1,0
render turbofan-front turbofan 1200 750 0.0 --eye -30,3,7 --look -11,0,0
render ironman ironMan 900 1000 0.0
render ironman-close ironMan 900 900 0.0 --eye 3.5,13.5,6.5 --look 0.3,12.8,0
render face face 900 900 0.0 --eye 0.3,15.6,6.0 --look -0.02,15.3,0
render glasses glasses 1200 750 0.0
render sunglasses sunglasses 1200 750 0.0
render showcase showcase 1200 750 0.0
render chandelier chandelier 1200 780 0.3
render sportscar sportsCar 1200 750 0.55
