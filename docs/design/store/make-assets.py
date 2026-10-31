#!/usr/bin/env python3
"""한데 스토어 자산 생성기 (3차-B). headless Chrome 으로 HTML → PNG.
  python3 make-assets.py            # icon-512 · feature-1024x500 · og-1200x630 · screenshot templates(5 × Play/iPhone)
  python3 make-assets.py --shot play 3 capture.png   # 틀 3번에 실기기 캡처 합성 → out/play-03.png
정본 마크: ../icons/hande-mark-master.svg (점 크림3·파랑3 교대). 글꼴: fonts/questrial-latin.woff2(OFL, 워드마크만) + 시스템 한글.
"""
import os, subprocess, sys, tempfile, shutil
from PIL import Image
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'out'); os.makedirs(OUT, exist_ok=True)
MARK = os.path.join(HERE, '..', 'icons', 'hande-mark-master.svg')
FONT = os.path.join(HERE, 'fonts', 'questrial-latin.woff2')
NIGHT = "background:#0F1324;background-image:radial-gradient(ellipse 70% 80% at 50% 115%,#5A2C12 0%,rgba(90,44,18,.45) 45%,rgba(90,44,18,0) 100%)"
CSS = f"""@font-face{{font-family:Q;src:url('file://{FONT}') format('woff2')}}
*{{box-sizing:border-box}} body{{margin:0;font-family:-apple-system,'Apple SD Gothic Neo','Noto Sans KR','Noto Sans CJK KR',Roboto,sans-serif;color:#F3E6D3}}
.wm{{font-family:Q,sans-serif;letter-spacing:.04em;line-height:1;color:#F3E6D3}}"""
def mark_fg(size):  # 배경 없는 전경 마크(마스터 SVG에서 배경 rect 2개 제거, 1.3배 확대)
    svg = open(MARK).read()
    body = svg.split('</defs>')[1].split('</svg>')[0]
    body = body.replace('<path d="M0 0H1024V1024H0Z" fill="#0F1324"/>','').replace('<path d="M0 0H1024V1024H0Z" fill="url(#glow)"/>','')
    return f'<svg width="{size}" height="{size}" viewBox="0 0 1024 1024"><g transform="translate(512 548) scale(1.3) translate(-512 -548)">{body}</g></svg>'
def render(html, w, h, out, transparent=False):
    f = tempfile.NamedTemporaryFile('w', suffix='.html', delete=False); f.write(f'<html><head><meta charset="utf-8"><style>{CSS}</style></head><body>{html}</body></html>'); f.close()
    bg = ['--default-background-color=00000000'] if transparent else []
    subprocess.run(['google-chrome','--headless=new','--no-sandbox','--disable-gpu','--hide-scrollbars',*bg,f'--window-size={w},{h}','--virtual-time-budget=4000',f'--screenshot={out}',f'file://{f.name}'],capture_output=True)
    os.unlink(f.name)
    if not transparent: Image.open(out).convert('RGB').save(out)
    return out
def icon512():
    out = os.path.join(OUT,'play-icon-512.png')
    subprocess.run(['bash', os.path.join(HERE,'..','icons','render.sh'), MARK, out, '512', '0'])
    Image.open(out).convert('RGB').save(out); return out
def feature():
    html = f'<div style="width:1024px;height:500px;{NIGHT};display:flex;align-items:center;gap:56px;padding:0 96px"><div style="width:300px;height:300px;flex:none">{mark_fg(300)}</div><div style="display:flex;flex-direction:column;gap:20px"><span class="wm" style="font-size:96px;text-shadow:0 0 28px rgba(245,158,66,.35)">hande</span><span style="font-size:30px;font-weight:600">한데 — 사람과 에이전트가 한데</span><span style="font-size:20px;color:#C9B89C">가족 운영자의 서버로 쓰는 비공개 메신저</span></div></div>'
    return render(html,1024,500,os.path.join(OUT,'play-feature-1024x500.png'))
def og():
    html = f'<div style="width:1200px;height:630px;{NIGHT};position:relative;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:22px"><div style="width:220px;height:220px">{mark_fg(220)}</div><span class="wm" style="font-size:88px;text-shadow:0 0 28px rgba(245,158,66,.35)">hande</span><span style="font-size:30px;font-weight:600">한데 — 사람과 에이전트가 한데</span><span style="position:absolute;bottom:36px;font-family:ui-monospace,Menlo,monospace;font-size:18px;color:#C9B89C">jinwon-int.github.io/family-messenger/hande</span></div>'
    return render(html,1200,630,os.path.join(OUT,'og-1200x630.png'))
SHOTS = [('서버 찾기','가입 없이, 가족 서버로','운영자가 등록한 가족만 들어옵니다'),('대화 목록','오늘 밤, 모닥불에 한데 모여','가족과 불지기가 한 자리에'),('대화(불지기 답장·허락 카드)','불지기는 먼저 허락을 구해요','바깥 일을 하기 전에 대상·내용·영향을 보여 줍니다'),('새 기기 승인','새 기기는 내 기기에서 승인','두 화면의 지문을 한 줄씩 맞춰 봅니다'),('설정','밤에도, 밝은 곳에서도','낮불 테마 · 잠금화면엔 「새 메시지」만')]
SPEC = {'play':(1080,1920,104,0.73,96), 'iphone':(1320,2868,150,0.76,136)}  # w,h,top,device width ratio,frame radius
def shot_frame(platform, n, capture=None):
    w,h,top,ratio,rad = SPEC[platform]; screen,title,sub = SHOTS[n-1]
    dw = int(w*ratio); img = f'<img src="file://{os.path.abspath(capture)}" style="width:100%;display:block">' if capture else f'<div style="position:absolute;inset:40px;border:6px dashed rgba(255,215,154,.45);border-radius:{rad-20}px;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:24px;text-align:center;padding:40px"><span style="font-size:44px;color:#FFD79A;font-weight:600">실기기 캡처 자리</span><span style="font-size:36px;color:#C9B89C;line-height:1.45">{screen}</span></div>'
    html = f'<div style="width:{w}px;height:{h}px;{NIGHT};display:flex;flex-direction:column;align-items:center;overflow:hidden"><div style="padding:{top}px 72px 56px;display:flex;flex-direction:column;gap:24px;text-align:center"><span style="font-size:76px;font-weight:700;line-height:1.3">{title}</span><span style="font-size:44px;color:#C9B89C;line-height:1.45">{sub}</span></div><div style="width:{dw}px;flex:1;margin-bottom:-120px;border-radius:{rad}px {rad}px 0 0;border:20px solid #23283C;border-bottom:0;background:#0F1324;overflow:hidden;position:relative">{img}</div></div>'
    return render(html,w,h,os.path.join(OUT,f'{platform}-{n:02d}{"" if capture else "-template"}.png'))
if __name__ == '__main__':
    if len(sys.argv) >= 4 and sys.argv[1] == '--shot':
        print(shot_frame(sys.argv[2], int(sys.argv[3]), sys.argv[4])); sys.exit()
    print(icon512()); print(feature()); print(og())
    for p in SPEC:
        for n in range(1,6): print(shot_frame(p,n))
