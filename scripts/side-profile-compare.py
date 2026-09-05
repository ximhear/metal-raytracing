import struct, sys, math

def read_bmp(path):
    d = open(path, 'rb').read()
    off = struct.unpack_from('<I', d, 10)[0]
    w, h = struct.unpack_from('<ii', d, 18)
    bpp = struct.unpack_from('<H', d, 28)[0]
    bottom_up = h > 0; h = abs(h)
    bytespp = bpp // 8
    stride = ((w * bytespp + 3) // 4) * 4
    def px(x, y):
        row = (h - 1 - y) if bottom_up else y
        i = off + row * stride + x * bytespp
        b, g, r = d[i], d[i+1], d[i+2]
        return r, g, b
    return w, h, px

def analyze(path, red_test, dark=34, step=2, mode='first', ground_override=None):
    w, h, px = read_bmp(path)
    top, bot = {}, {}
    for x in range(0, w, step):
        runs = []; y = 0; first = None
        while y < h:
            r, g, b = px(x, y)
            if red_test(r, g, b):
                if first is None: first = y
            elif first is not None:
                runs.append((first, y - 1)); first = None
                if mode == 'first': break
            y += 1
        if first is not None: runs.append((first, h - 1))
        if runs:
            a, b2 = runs[0] if mode == 'first' else max(runs, key=lambda r: r[1] - r[0])
            top[x] = a; bot[x] = b2
    xs = sorted(top)
    # 차체 x 범위: 붉은 런이 세로로 6px 이상인 열만 (범퍼 끝의 얇은 것 제외)
    xs = [x for x in xs if bot[x] - top[x] > 6]
    x0, x1 = xs[0], xs[-1]
    tops = sorted(top[x] for x in xs)
    sill = sorted(bot[x] for x in xs)[int(len(xs) * 0.45)]
    body_h = sill - tops[len(tops) // 2]
    # 아치: 아래 가장자리가 문턱보다 차체 높이의 20% 이상 올라간 열의 연속 구간 둘
    arch_cols = [x for x in xs if bot[x] < sill - 0.2 * body_h]
    runs = []
    for x in arch_cols:
        if runs and x - runs[-1][-1] <= step * 3: runs[-1].append(x)
        else: runs.append([x])
    runs = sorted(runs, key=len, reverse=True)[:2]
    runs = sorted(runs, key=lambda r: r[0])
    axles = [(r[0] + r[-1]) / 2 for r in runs]
    # 바닥선: 차축 열에서 아래로 내려가며 **밝은 스포크 영역을 지난 뒤** 어두운(타이어) 런의 끝.
    # 도로·바닥은 타이어보다 밝다
    ground = 0
    if ground_override is None:
        for ax in axles:
            for x in range(int(ax) - step * 6, int(ax) + step * 6 + 1, step):
                if x not in bot: continue
                y = bot[x] + 1; seen_bright = False; last = None
                while y < h and y < bot[x] + int(2.0 * body_h):
                    r, g, b = px(x, y); lum = (r + g + b) // 3
                    if lum > 150: seen_bright = True
                    if seen_bright and lum < dark: last = y
                    y += 1
                if last: ground = max(ground, last)
    else:
        ground = ground_override
    print(f"  {path}: 차체높이 {body_h}px, 문턱 y {sill}, 바닥 y {ground}, 차축 x {[round(a) for a in axles]}")
    return dict(w=w, h=h, top=top, bot=bot, xs=xs, x0=x0, x1=x1, ground=ground, axles=axles, sill=sill)

GROUND_MODEL = 512   # 카메라 (0,4.4,-75)·FOV 50°·근측 타이어 z=-6.9 → 바닥 y=0 의 행
photo = analyze('photo.bmp', lambda r, g, b: r > 45 and r > 1.6 * g and g <= 1.1 * b, dark=90, mode='longest')
model = analyze('model.bmp', lambda r, g, b: r > 40 and r > 1.6 * g and g <= 1.15 * b, dark=70, ground_override=GROUND_MODEL)

def metrics(a, flip):
    # 사진: 앞이 오른쪽. 모델 렌더: 앞이 왼쪽 → flip
    ax = a['axles']
    front, rear = (max(ax), min(ax)) if not flip else (min(ax), max(ax))
    wb = abs(front - rear)
    sgn = 1 if not flip else -1          # 앞 방향 부호
    def X(x): return (x - front) * sgn / wb        # 앞차축 0, 앞이 +
    def Y(y): return (a['ground'] - y) / wb
    xs = a['xs']
    xf = a['x1'] if not flip else a['x0']
    xr = a['x0'] if not flip else a['x1']
    prof = {}
    for x in xs:
        prof[round(X(x), 3)] = Y(a['top'][x])
    def top_at(u):   # 정규화 x=u 에서의 윗면 높이 (가장 가까운 열)
        k = min(prof, key=lambda t: abs(t - u)); return prof[k]
    return dict(wb=wb, length=abs(xf - xr) / wb, front_oh=X(xf), rear_oh=-X(xr),
                h_nose=top_at(0.38), h_front_axle=top_at(0.0), h_cowl=top_at(-0.25),
                h_door=top_at(-0.5), h_rear_axle=top_at(-1.0), h_tail=top_at(-1.35),
                sill=Y(a['sill']), prof=prof, X=X, Y=Y)

P, M = metrics(photo, False), metrics(model, True)
WB = 2.44
rows = [("전장 / 휠베이스", 'length'), ("앞 오버행 / 휠베이스", 'front_oh'), ("뒤 오버행 / 휠베이스", 'rear_oh'),
        ("코 높이 (앞차축 앞 0.38)", 'h_nose'), ("보닛 높이 (앞차축)", 'h_front_axle'), ("카울 높이 (−0.25)", 'h_cowl'),
        ("도어 윗선 (−0.5)", 'h_door'), ("리어 데크 (뒤차축)", 'h_rear_axle'), ("꼬리 (−1.35)", 'h_tail'), ("문턱 높이", 'sill')]
print(f"{'항목':<24} {'사진':>8} {'모델':>8} {'차이':>8}   (휠베이스 = 1, 실측 m 환산은 ×2.44)")
for name, k in rows:
    p, m = P[k], M[k]
    print(f"{name:<24} {p:8.3f} {m:8.3f} {m-p:+8.3f}   ({(m-p)*WB*100:+.0f} cm)")

# 오버레이 BMP: 두 실루엣 윗선·아랫선을 그린다
W, H = 1400, 520
img = bytearray(b'\xff' * (W * H * 3))
def put(x, y, c):
    if 0 <= x < W and 0 <= y < H:
        i = (y * W + x) * 3; img[i], img[i+1], img[i+2] = c[2], c[1], c[0]
def draw(a, m, flip, color):
    sc = 380.0  # px per 휠베이스
    ox, oy = 1000, 420
    xs = a['xs']
    pts_t, pts_b = [], []
    for x in xs:
        u = m['X'](x); pts_t.append((int(ox + u * sc), int(oy - m['Y'](a['top'][x]) * sc)))
        pts_b.append((int(ox + u * sc), int(oy - m['Y'](a['bot'][x]) * sc)))
    for pts in (pts_t, pts_b):
        for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
            n = max(abs(x2 - x1), abs(y2 - y1), 1)
            for i in range(n + 1):
                t = i / n
                for dx in (-1, 0, 1):
                    for dy in (-1, 0, 1):
                        put(int(x1 + (x2 - x1) * t) + dx, int(y1 + (y2 - y1) * t) + dy, color)
    for ax in a['axles']:
        cx = int(ox + m['X'](ax) * sc)
        for y in range(oy - 8, oy + 8): put(cx, y, color)
for y in range(H): put(1000, y, (200, 200, 200)); put(int(1000 - 380), y, (200, 200, 200))
for x in range(W): put(x, 420, (200, 200, 200))
draw(photo, P, False, (0, 0, 0))
draw(model, M, True, (220, 30, 30))
hdr = struct.pack('<2sIHHI', b'BM', 54 + W * H * 3, 0, 0, 54) + struct.pack('<IiiHHIIiiII', 40, W, -H, 1, 24, 0, W * H * 3, 2835, 2835, 0, 0)
open('overlay.bmp', 'wb').write(hdr + bytes(img))
print("사진 휠베이스 px:", round(P['wb']), " 모델:", round(M['wb']))
