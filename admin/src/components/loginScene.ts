// 登录页背景：版画风格的蓝色山野，canvas 程序绘制（不用图片素材）。
// 远山、中丘、近丘、原野和草丛按远慢近快分层移动，天上有淡云飘过。
// 山和云在窗口尺寸变化时画一次，缓存成可平铺的条带；每帧只做平移、原野横线和草丛。
// 系统开了「减少动态效果」时只画一帧静止画面。

const C = { sky: '#213E9F', ink: '#1A338C', inkFar: '#2C4BAF', paper: '#F3E8CC', grass: '#142A78' };

type Noise = (x: number) => number;

function rng(seed: number): () => number {
  let a = seed;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Value noise that repeats every P pixels (lattice spacing about s px). */
function pnoise(seed: number, P: number, s: number): Noise {
  const n = Math.max(1, Math.round(P / s));
  const r = rng(seed);
  const v = new Float32Array(n);
  for (let i = 0; i < n; i++) v[i] = r();
  return (x) => {
    const q = (x * n) / P;
    let i = Math.floor(q);
    const f = q - i;
    i = ((i % n) + n) % n;
    const a = v[i];
    const b = v[(i + 1) % n];
    const u = f * f * (3 - 2 * f);
    return a + (b - a) * u;
  };
}

const wrap = (d: number, P: number) => d - P * Math.round(d / P);
const ease = (t: number) => 1 - Math.pow(1 - Math.min(1, Math.max(0, t)), 3);

interface RangeDef {
  idx: number;
  seed: number;
  base: number;
  count: number;
  w: [number, number];
  h: [number, number];
  mesa: number;
  hero?: number;
  gap: number;
  lw: number;
  ink: string;
  speed: number;
}
interface Layer {
  canvas: HTMLCanvasElement;
  top: number;
  P: number;
  speed: number;
  idx: number;
}
interface Cloud {
  canvas: HTMLCanvasElement;
  w: number;
  h: number;
  y: number;
  x0: number;
  speed: number;
}
interface PlainLine {
  y: number;
  lw: number;
  dash: number[];
  phase: number;
  a: number;
}
interface Blade {
  a: number;
  len: number;
  bend: number;
  bx: number;
}
interface Tuft {
  u: number;
  y: number;
  s: number;
  blades: Blade[];
  ph: number;
}
interface Scene {
  W: number;
  H: number;
  dpr: number;
  u: number;
  plainTop: number;
  yH: number;
  refY: number;
  speed: number;
  layers: Layer[];
  clouds: Cloud[];
  plain: PlainLine[];
  tufts: Tuft[];
  margin: number;
  Pp: number;
}

function newCanvas(w: number, h: number): [HTMLCanvasElement, CanvasRenderingContext2D] {
  const c = document.createElement('canvas');
  c.width = Math.max(1, Math.ceil(w));
  c.height = Math.max(1, Math.ceil(h));
  return [c, c.getContext('2d')!];
}

/** One hill range, drawn once into a strip that tiles every P pixels. */
function range(S: Pick<Scene, 'H' | 'dpr' | 'u'>, def: RangeDef, P: number, plainTop: number): Layer {
  const { H, dpr, u } = S;
  const r = rng(def.seed);
  const peaks: { c: number; w: number; h: number; mesa: boolean }[] = [];
  const count = Math.round((def.count * P) / 2160);
  for (let k = 0; k < count; k++) {
    peaks.push({
      c: ((k + r() * 0.8) / count) * P,
      w: (def.w[0] + r() * (def.w[1] - def.w[0])) * u,
      h: (def.h[0] + r() * (def.h[1] - def.h[0])) * H,
      mesa: r() < def.mesa,
    });
  }
  if (def.hero) peaks.push({ c: 0.6 * P, w: 210 * u, h: def.hero * H, mesa: true });
  const n1 = pnoise(def.seed + 1, P, 26);
  const n2 = pnoise(def.seed + 2, P, 7);
  const R = new Float32Array(P + 3);
  let minR = Infinity;
  for (let x = 0; x <= P + 2; x++) {
    let y = def.base * H;
    for (const p of peaks) {
      const t = wrap(x - p.c, P) / p.w;
      y -= p.h * (p.mesa ? 1 / (1 + t * t * t * t) : Math.exp(-t * t * 1.4));
    }
    y += (n1(x) - 0.5) * 5 * u + (n2(x) - 0.5) * 1.6 * u;
    R[x] = y;
    if (y < minR) minR = y;
  }
  const top = Math.floor(minR - 3);
  const bottom = plainTop + 6;
  const [c, g] = newCanvas(P * dpr, (bottom - top) * dpr);
  g.scale(dpr, dpr);
  g.translate(0, -top);
  g.fillStyle = C.paper;
  g.beginPath();
  g.moveTo(0, bottom);
  for (let x = 0; x <= P; x += 2) g.lineTo(x, R[x]);
  g.lineTo(P, bottom);
  g.closePath();
  g.fill();

  // Engraved contour lines: each follows the ridge and flattens toward the plain.
  // Slopes facing right are in shadow (denser lines); lines thin out where they bunch up.
  const gap = Math.max(2, def.gap * u);
  const lines = Math.ceil((bottom - minR) / gap);
  const tex = pnoise(def.seed + 3, P, 46);
  g.strokeStyle = def.ink;
  g.lineCap = 'round';
  for (let i = 1; i <= lines; i++) {
    const T = Math.pow(i / lines, 1.25);
    const Tp = Math.pow((i - 1) / lines, 1.25);
    const gate = pnoise(def.seed + 10 + i, P, 5 + (i % 4) * 2.5);
    g.lineWidth = def.lw * (0.85 + r() * 0.35);
    g.beginPath();
    let on = false;
    for (let x = 0; x <= P; x += 2) {
      const Rx = R[x];
      const y = Rx + (bottom - Rx) * T;
      const xm = x < 2 ? x + P - 2 : x - 2;
      const slope = ((R[x + 2] - R[xm]) / 4) * (1 - T);
      const shade = 0.5 + 0.5 * Math.tanh(slope * 3);
      const space = Math.min(1, ((bottom - Rx) * (T - Tp)) / gap);
      const p = i <= 1 ? 1 : (0.1 + 0.9 * Math.pow(shade, 1.2)) * Math.pow(space, 0.8) * (0.7 + 0.6 * tex(x + i * 3));
      if (gate(x) < p) {
        if (on) g.lineTo(x, y);
        else g.moveTo(x, y);
        on = true;
      } else on = false;
    }
    g.stroke();
  }
  return { canvas: c, top, P, speed: def.speed * u, idx: def.idx };
}

function cloud(S: Pick<Scene, 'H' | 'dpr' | 'u'>, seed: number): Cloud {
  const { H, dpr, u } = S;
  const r = rng(seed);
  const cw = (170 + r() * 170) * u;
  const ch = cw * 0.32;
  const blobs: { x: number; y: number; rx: number; ry: number }[] = [];
  const k = 3 + Math.floor(r() * 3);
  for (let i = 0; i < k; i++) {
    blobs.push({ x: cw * (0.18 + (0.64 * (i + r() * 0.6)) / k), y: ch * (0.45 + r() * 0.25), rx: cw * (0.14 + r() * 0.12), ry: ch * (0.28 + r() * 0.22) });
  }
  const [c, g] = newCanvas(cw * dpr, ch * dpr);
  g.scale(dpr, dpr);
  g.strokeStyle = 'rgba(243,232,204,.2)';
  g.lineWidth = 0.8;
  g.lineCap = 'round';
  const gate = pnoise(seed + 7, 4000, 6);
  for (let y = 2, row = 0; y < ch; y += 2.6, row++) {
    g.beginPath();
    let on = false;
    for (let x = 0; x < cw; x += 2) {
      const inside = blobs.some((b) => {
        const dx = (x - b.x) / b.rx;
        const dy = (y - b.y) / b.ry;
        return dx * dx + dy * dy < 1;
      });
      const p = inside ? 0.25 + 0.6 * (y / ch) : 0;
      if (gate(x + row * 97) < p) {
        if (on) g.lineTo(x, y);
        else g.moveTo(x, y);
        on = true;
      } else on = false;
    }
    g.stroke();
  }
  return { canvas: c, w: cw, h: ch, y: H * (0.06 + r() * 0.3), x0: r(), speed: (4 + r() * 5) * u };
}

function build(canvas: HTMLCanvasElement): Scene {
  const W = Math.max(1, canvas.clientWidth);
  const H = Math.max(1, canvas.clientHeight);
  const dpr = Math.min(2, window.devicePixelRatio || 1);
  canvas.width = Math.round(W * dpr);
  canvas.height = Math.round(H * dpr);
  const u = Math.max(0.6, H / 900);
  const base = { H, dpr, u };
  const P = 2160 * Math.ceil((W + 40) / 2160);
  const plainTop = Math.round(H * 0.735);
  const defs: RangeDef[] = [
    { idx: 0, seed: 11, base: 0.69, count: 3, w: [110, 260], h: [0.04, 0.085], mesa: 0.5, hero: 0.11, gap: 2.4, lw: 0.7, ink: C.inkFar, speed: 3 },
    { idx: 1, seed: 23, base: 0.718, count: 5, w: [90, 210], h: [0.025, 0.055], mesa: 0.3, gap: 2.8, lw: 0.85, ink: C.ink, speed: 9 },
    { idx: 2, seed: 37, base: 0.745, count: 7, w: [70, 170], h: [0.012, 0.03], mesa: 0.2, gap: 3.2, lw: 1, ink: C.ink, speed: 20 },
  ];
  const layers = defs.map((d) => range(base, d, P, plainTop));

  // Plain: perspective streaks; spacing, width and speed grow toward the viewer.
  const r = rng(91);
  const yH = plainTop - H * 0.06;
  const plain: PlainLine[] = [];
  for (let y = plainTop + 1.5; y < H + 2; ) {
    const d = y - yH;
    const sc = d / 100;
    const dash: number[] = [];
    for (let j = 0; j < 8; j++) dash.push((3 + r() * r() * 42) * sc, (2 + r() * r() * 28) * sc);
    plain.push({ y, lw: 0.45 + (d / H) * 2.2, dash, phase: r() * 500, a: 0.45 + r() * 0.5 });
    y += Math.max(2.2, d * 0.045);
  }
  // Grass tufts, back to front.
  const N = Math.round(Math.max(60, Math.min(260, (W * (H - plainTop)) / 2600)));
  const tufts: Tuft[] = [];
  for (let i = 0; i < N; i++) {
    const y = plainTop + 4 + (H - plainTop + 16) * Math.pow(r(), 0.85);
    const s = (y - yH) * 0.09 * (0.5 + r());
    const blades: Blade[] = [];
    const m = 5 + Math.floor(r() * 9);
    for (let j = 0; j < m; j++) {
      const off = (r() - 0.5) * 1.9;
      blades.push({ a: -Math.PI / 2 + off, len: s * (0.55 + r() * 0.6) * (1 - 0.3 * Math.abs(off)), bend: (r() - 0.5) * 0.7, bx: (r() - 0.5) * s * 0.25 });
    }
    tufts.push({ u: r(), y, s, blades, ph: r() * 6.28 });
  }
  tufts.sort((a, b) => a.y - b.y);
  const refY = plainTop + (H - plainTop) * 0.42;
  const margin = 80;
  return {
    W,
    H,
    dpr,
    u,
    plainTop,
    yH,
    refY,
    speed: 70 * u,
    layers,
    clouds: [101, 202, 303, 404].map((s) => cloud(base, s)),
    plain,
    tufts,
    margin,
    Pp: W + margin * 2,
  };
}

function draw(ctx: CanvasRenderingContext2D, S: Scene, t: number, intro: number) {
  const { W, H, dpr } = S;
  // Ground distance travelled at the reference depth; nearer ground moves proportionally faster.
  const D = t * S.speed;
  const ratio = (y: number) => (y - S.yH) / (S.refY - S.yH);
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.fillStyle = C.sky;
  ctx.fillRect(0, 0, W, H);

  for (const c of S.clouds) {
    const span = W + c.w;
    const x = ((((c.x0 * span - t * c.speed) % span) + span) % span) - c.w;
    ctx.drawImage(c.canvas, x, c.y, c.w, c.h);
  }
  for (const L of S.layers) {
    const off = (((t * L.speed) % L.P) + L.P) % L.P;
    const dy = (1 - intro) * H * 0.035 * (L.idx + 1);
    const w = L.canvas.width / dpr;
    const h = L.canvas.height / dpr;
    for (let x = -off; x < W; x += L.P) ctx.drawImage(L.canvas, x, L.top + dy, w, h);
  }

  ctx.fillStyle = C.paper;
  ctx.fillRect(0, S.plainTop, W, H - S.plainTop);
  ctx.strokeStyle = C.ink;
  ctx.lineCap = 'butt';
  for (const l of S.plain) {
    ctx.globalAlpha = l.a;
    ctx.lineWidth = l.lw;
    ctx.setLineDash(l.dash);
    ctx.lineDashOffset = l.phase + D * ratio(l.y);
    ctx.beginPath();
    ctx.moveTo(0, l.y);
    ctx.lineTo(W, l.y);
    ctx.stroke();
  }
  ctx.setLineDash([]);
  ctx.globalAlpha = 1;

  ctx.lineCap = 'round';
  ctx.strokeStyle = C.grass;
  for (const f of S.tufts) {
    const x = ((((f.u * S.Pp - D * ratio(f.y)) % S.Pp) + S.Pp) % S.Pp) - S.margin;
    const wind = Math.sin(t * 1.25 + f.u * 9 + f.ph * 0.3) * 0.09 + Math.sin(t * 2.7 + f.ph) * 0.03;
    ctx.lineWidth = Math.max(0.7, f.s * 0.055);
    ctx.beginPath();
    for (const b of f.blades) {
      const a = b.a + wind * (1 + b.len / f.s);
      const bx = x + b.bx;
      ctx.moveTo(bx, f.y);
      ctx.quadraticCurveTo(bx + Math.cos(a - b.bend) * b.len * 0.55, f.y + Math.sin(a - b.bend) * b.len * 0.55, bx + Math.cos(a) * b.len, f.y + Math.sin(a) * b.len);
    }
    ctx.moveTo(x - f.s * 0.45, f.y + 1);
    ctx.lineTo(x + f.s * 0.5, f.y + 1);
    ctx.stroke();
  }
}

/** Paper grain as a small tile (data URL) for a CSS background. */
export function grainTile(): string {
  const n = 180;
  const [c, g] = newCanvas(n, n);
  const img = g.createImageData(n, n);
  const r = rng(5);
  for (let i = 0; i < img.data.length; i += 4) {
    const dark = r() < 0.5;
    img.data[i] = dark ? 8 : 255;
    img.data[i + 1] = dark ? 18 : 246;
    img.data[i + 2] = dark ? 70 : 222;
    img.data[i + 3] = r() * (dark ? 44 : 30);
  }
  g.putImageData(img, 0, 0);
  return c.toDataURL();
}

/** Starts the animated landscape on [canvas]; returns a function that stops it. */
export function startLoginScene(canvas: HTMLCanvasElement): () => void {
  const ctx = canvas.getContext('2d');
  if (!ctx) return () => {};
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  let S = build(canvas);
  let t = 0;
  let last = 0;
  let raf = 0;
  const frame = (now: number) => {
    const dt = last ? Math.min(0.05, (now - last) / 1000) : 0;
    last = now;
    t += dt;
    draw(ctx, S, t, ease(t / 1.8));
    raf = requestAnimationFrame(frame);
  };
  if (reduce) draw(ctx, S, 8, 1);
  else raf = requestAnimationFrame(frame);

  let timer = 0;
  let first = true;
  const ro = new ResizeObserver(() => {
    if (first) {
      first = false; // observe() reports the current size once; the scene is already built for it.
      return;
    }
    window.clearTimeout(timer);
    timer = window.setTimeout(() => {
      S = build(canvas);
      if (reduce) draw(ctx, S, 8, 1);
    }, 150);
  });
  ro.observe(canvas);
  return () => {
    cancelAnimationFrame(raf);
    window.clearTimeout(timer);
    ro.disconnect();
  };
}
