"""hande 워드마크 윤곽 생성기: OFL 1.1 글꼴(가변이면 굵기 고정) → 글자 윤곽 SVG path(y 아래 방향, 왼쪽 위 원점, 1em=1000).
# 의존: fonttools (pip install fonttools). 글꼴 파일은 저장소에 두지 않는다 — Questrial Regular: https://github.com/google/fonts/tree/main/ofl/questrial
사용: python make_wordmark_path.py <font> <wght|-> <tracking_em>  → JSON {d, width, height}"""
import sys, json
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.boundsPen import BoundsPen

TEXT = "hande"
font, warg, track = sys.argv[1], sys.argv[2], float(sys.argv[3])
f = TTFont(font)
wght = None if warg == "-" else float(warg)
if wght is not None:
    f = instantiateVariableFont(f, {"wght": wght})
gs, cmap, hmtx = f.getGlyphSet(), f.getBestCmap(), f["hmtx"]
upm = f["head"].unitsPerEm
k = 1000.0 / upm
# 1차: 경계 상자
x, placed = 0.0, []
for ch in TEXT:
    g = cmap[ord(ch)]
    placed.append((g, x))
    x += hmtx[g][0] + track * upm
bp = BoundsPen(gs)
for g, gx in placed:
    gs[g].draw(TransformPen(bp, (1, 0, 0, 1, gx, 0)))
xmin, ymin, xmax, ymax = bp.bounds
# 2차: y 뒤집고 (xmin, ymax) 를 원점으로
sp = SVGPathPen(gs, ntos=lambda v: ("%.1f" % v).rstrip("0").rstrip("."))
for g, gx in placed:
    gs[g].draw(TransformPen(sp, (k, 0, 0, -k, (gx - xmin) * k, ymax * k)))
print(json.dumps({"d": sp.getCommands(), "width": round((xmax - xmin) * k, 1), "height": round((ymax - ymin) * k, 1), "font": font.rsplit("/", 1)[-1], "wght": wght, "tracking": track}))
