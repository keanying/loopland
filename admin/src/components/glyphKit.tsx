// Drawing core for the glyphs (see Glyph.tsx): name → definition, stroke width per size, SVG output.
import type { ReactNode } from 'react';
import { APP_GLYPHS, type GlyphDef, type GlyphPart } from './glyphs';
import { ADMIN_GLYPHS } from './glyphsAdmin';

type Overlap = keyof typeof APP_GLYPHS & keyof typeof ADMIN_GLYPHS;
// A glyph name in both sets is a mistake: the App's drawing wins and the admin copy is dead code.
const noOverlap: [Overlap] extends [never] ? true : { duplicate: Overlap } = true;
void noOverlap;

export const GLYPHS: Record<GlyphName, GlyphDef> = { ...APP_GLYPHS, ...ADMIN_GLYPHS };
export type GlyphName = keyof typeof APP_GLYPHS | keyof typeof ADMIN_GLYPHS;

/** Stroke width in grid units for an icon of `px` pixels (LGlyph.strokeUnits in the App). */
export function strokeUnits(px: number): number {
  if (px <= 24) return 1.8 + Math.min(Math.max(24 - px, 0), 12) * 0.04;
  return 1.8 - Math.min(Math.max(px - 24, 0), 32) * 0.008;
}

/** Stroke width for size="1em" (follows the font size; icons next to text are 12–18 px). */
export const EM_STROKE = 2.05;

const circle = /O\s*(-?[\d.]+)[\s,]+(-?[\d.]+)[\s,]+([\d.]+)/g;
const pathCache = new Map<string, string>();
const n = (v: number) => +v.toFixed(3);

/** Plain SVG path data: `O cx cy r` → two arcs. */
export function svgPath(d: string): string {
  let p = pathCache.get(d);
  if (p === undefined) {
    p = d.replace(circle, (_, x: string, y: string, rr: string) => {
      const cx = +x, cy = +y, r = +rr;
      return `M${n(cx - r)} ${n(cy)}a${n(r)} ${n(r)} 0 1 0 ${n(2 * r)} 0a${n(r)} ${n(r)} 0 1 0 ${n(-2 * r)} 0z`;
    });
    pathCache.set(d, p);
  }
  return p;
}

/** One drawing step: the parts to draw, then the cuts that erase everything drawn so far. */
interface Layer {
  draw: GlyphPart[];
  cuts: GlyphPart[];
}

function layers(g: GlyphDef): Layer[] {
  const out: Layer[] = [];
  let cur: Layer = { draw: [], cuts: [] };
  for (const p of g.parts) {
    if (p.cut) cur.cuts.push(p);
    else {
      if (cur.cuts.length) {
        out.push(cur);
        cur = { draw: [], cuts: [] };
      }
      cur.draw.push(p);
    }
  }
  out.push(cur);
  return out;
}

const BOX = { x: -4, y: -4, width: 32, height: 32 };
const round = { strokeLinecap: 'round', strokeLinejoin: 'round' } as const;

function partEl(p: GlyphPart, sw: number, color: string, key: number) {
  const d = svgPath(p.d);
  if (p.fill) return <path key={key} d={d} fill={color} stroke={color} strokeWidth={p.cut ? 0.5 : 0.9} {...round} />;
  return <path key={key} d={d} fill="none" stroke={color} strokeWidth={Math.max(0.1, sw + (p.extra ?? 0))} {...round} />;
}

/** The SVG children of a glyph (paths, plus masks for the cut-outs). `uid` keeps mask ids unique on the page. */
export function glyphNodes(g: GlyphDef, sw: number, uid: string, color = 'currentColor'): ReactNode {
  const defs: ReactNode[] = [];
  let body: ReactNode[] = [];
  layers(g).forEach((l, i) => {
    body.push(...l.draw.map((p, j) => partEl(p, sw, color, i * 100 + j)));
    if (l.cuts.length) {
      const id = `${uid}m${i}`;
      defs.push(
        <mask key={id} id={id} maskUnits="userSpaceOnUse" {...BOX}>
          <rect {...BOX} fill="#fff" />
          {l.cuts.map((p, j) => partEl(p, sw, '#000', j))}
        </mask>,
      );
      body = [
        <g key={id} mask={`url(#${id})`}>
          {body}
        </g>,
      ];
    }
  });
  return (
    <>
      {defs.length > 0 && <defs>{defs}</defs>}
      {body}
    </>
  );
}

/** The same glyph as a standalone SVG string (for CSS masks over Ant Design's own icons). Inline several on one page → give each an idPrefix. */
export function glyphSvgString(name: GlyphName, sw: number, idPrefix = ''): string {
  const g = GLYPHS[name];
  const attrs = 'stroke-linecap="round" stroke-linejoin="round"';
  const part = (p: GlyphPart, color: string) =>
    p.fill
      ? `<path d="${svgPath(p.d)}" fill="${color}" stroke="${color}" stroke-width="${p.cut ? 0.5 : 0.9}" ${attrs}/>`
      : `<path d="${svgPath(p.d)}" fill="none" stroke="${color}" stroke-width="${n(Math.max(0.1, sw + (p.extra ?? 0)))}" ${attrs}/>`;
  const box = `x="${BOX.x}" y="${BOX.y}" width="${BOX.width}" height="${BOX.height}"`;
  let defs = '';
  let body = '';
  layers(g).forEach((l, i) => {
    body += l.draw.map((p) => part(p, '#000')).join('');
    if (l.cuts.length) {
      defs += `<mask id="${idPrefix}m${i}" maskUnits="userSpaceOnUse" ${box}><rect ${box} fill="#fff"/>${l.cuts.map((p) => part(p, '#000')).join('')}</mask>`;
      body = `<g mask="url(#${idPrefix}m${i})">${body}</g>`;
    }
  });
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">${defs ? `<defs>${defs}</defs>` : ''}${body}</svg>`;
}

