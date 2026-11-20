import { useEffect, useMemo, useRef, useState } from 'react';
import { Button, Tooltip } from 'antd';
import { AimOutlined, MinusOutlined, PlusOutlined } from '@ant-design/icons';
import { ownerColor, rings, type MapProps } from './colors';

const PAD = 40;

interface View {
  s: number;
  tx: number;
  ty: number;
}

/**
 * Fallback map used when no AMap key is configured: projects the GeoJSON
 * polygons (GCJ-02 lng/lat) onto an SVG with an equirectangular projection.
 * No basemap; wheel to zoom, drag to pan.
 */
export default function SvgMap({ items, selectedId, onSelect, focus }: MapProps) {
  const svgRef = useRef<SVGSVGElement | null>(null);
  const wrapRef = useRef<HTMLDivElement | null>(null);
  // The viewBox follows the container's pixel size so the polygons fill it.
  const [size, setSize] = useState({ W: 1000, H: 520 });
  const { W, H } = size;
  useEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => {
      const r = el.getBoundingClientRect();
      if (r.width > 0 && r.height > 0) setSize({ W: Math.round(r.width), H: Math.round(r.height) });
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const [view, setView] = useState<View>({ s: 1, tx: 0, ty: 0 });
  const drag = useRef<{ x: number; y: number; tx: number; ty: number; moved: boolean } | null>(null);

  const proj = useMemo(() => {
    let minX = Infinity;
    let maxX = -Infinity;
    let minY = Infinity;
    let maxY = -Infinity;
    for (const t of items)
      for (const r of rings(t))
        for (const [lng, lat] of r) {
          minX = Math.min(minX, lng);
          maxX = Math.max(maxX, lng);
          minY = Math.min(minY, lat);
          maxY = Math.max(maxY, lat);
        }
    if (!Number.isFinite(minX)) return null;
    const k = Math.cos((((minY + maxY) / 2) * Math.PI) / 180);
    const spanX = Math.max((maxX - minX) * k, 1e-6);
    const spanY = Math.max(maxY - minY, 1e-6);
    const scale = Math.min((W - PAD * 2) / spanX, (H - PAD * 2) / spanY);
    const ox = (W - spanX * scale) / 2;
    const oy = (H - spanY * scale) / 2;
    return (lng: number, lat: number): [number, number] => [ox + (lng - minX) * k * scale, oy + (maxY - lat) * scale];
  }, [items, W, H]);

  // Wheel zoom needs a non-passive listener so the page does not scroll.
  useEffect(() => {
    const el = svgRef.current;
    if (!el) return;
    const onWheel = (e: WheelEvent) => {
      e.preventDefault();
      const rect = el.getBoundingClientRect();
      const px = ((e.clientX - rect.left) / rect.width) * W;
      const py = ((e.clientY - rect.top) / rect.height) * H;
      setView((v) => {
        const s = Math.min(12, Math.max(0.6, v.s * (e.deltaY < 0 ? 1.2 : 1 / 1.2)));
        return { s, tx: px - ((px - v.tx) / v.s) * s, ty: py - ((py - v.ty) / v.s) * s };
      });
    };
    el.addEventListener('wheel', onWheel, { passive: false });
    return () => el.removeEventListener('wheel', onWheel);
  }, [W, H]);

  useEffect(() => {
    if (!proj) return;
    if (!focus) {
      setView({ s: 1, tx: 0, ty: 0 });
      return;
    }
    const [x, y] = proj(focus.lng, focus.lat);
    const s = 2.4;
    setView({ s, tx: W / 2 - x * s, ty: H / 2 - y * s });
    // eslint-disable-next-line react-hooks/exhaustive-deps -- only re-center when asked
  }, [focus, proj]);

  const zoom = (f: number) =>
    setView((v) => {
      const s = Math.min(12, Math.max(0.6, v.s * f));
      return { s, tx: W / 2 - ((W / 2 - v.tx) / v.s) * s, ty: H / 2 - ((H / 2 - v.ty) / v.s) * s };
    });

  const toSvg = (dx: number) => dx; // viewBox is 1:1 with CSS pixels

  const owners = useMemo(() => {
    const m = new Map<string, string>();
    for (const t of items) {
      const name = t.owner ? t.owner.nickname : '无主';
      if (!m.has(name)) m.set(name, ownerColor(t.owner?.id));
    }
    return [...m.entries()].slice(0, 8);
  }, [items]);

  return (
    <div className="map-wrap" ref={wrapRef}>
      <svg
        ref={svgRef}
        viewBox={`0 0 ${W} ${H}`}
        width="100%"
        height="100%"
        preserveAspectRatio="none"
        style={{ display: 'block', position: 'absolute', inset: 0, cursor: 'grab', touchAction: 'none' }}
        role="img"
        aria-label="领地分布示意图"
        onPointerDown={(e) => {
          drag.current = { x: e.clientX, y: e.clientY, tx: view.tx, ty: view.ty, moved: false };
        }}
        onPointerMove={(e) => {
          const d = drag.current;
          if (!d) return;
          const dx = e.clientX - d.x;
          const dy = e.clientY - d.y;
          if (Math.abs(dx) + Math.abs(dy) > 3) d.moved = true;
          if (d.moved) setView((v) => ({ ...v, tx: d.tx + toSvg(dx), ty: d.ty + toSvg(dy) }));
        }}
        onPointerUp={() => {
          setTimeout(() => (drag.current = null), 0);
        }}
        onPointerLeave={() => (drag.current = null)}
      >
        <defs>
          <pattern id="grid" width="50" height="50" patternUnits="userSpaceOnUse">
            <path d="M 50 0 L 0 0 0 50" fill="none" stroke="#e4dccb" strokeWidth="1" />
          </pattern>
        </defs>
        <rect x={-W} y={-H} width={W * 3} height={H * 3} fill="url(#grid)" />
        <g transform={`translate(${view.tx} ${view.ty}) scale(${view.s})`}>
          {proj &&
            items.map((t) => {
              const sel = t.id === selectedId;
              const color = ownerColor(t.owner?.id);
              const d = rings(t)
                .map((r) => r.map(([lng, lat], i) => `${i ? 'L' : 'M'}${proj(lng, lat).map((n) => n.toFixed(1)).join(' ')}`).join(' ') + ' Z')
                .join(' ');
              return (
                <path
                  key={t.id}
                  d={d}
                  fill={color}
                  fillOpacity={sel ? 0.75 : 0.5}
                  fillRule="evenodd"
                  stroke={t.frozen ? '#2F6FD0' : sel ? '#141414' : '#3a3a40'}
                  strokeWidth={sel ? 3 : 1.4}
                  strokeDasharray={t.frozen ? '6 4' : undefined}
                  vectorEffect="non-scaling-stroke"
                  style={{ cursor: 'pointer' }}
                  onClick={() => !drag.current?.moved && onSelect(t.id)}
                >
                  <title>{`${t.name} · ${t.owner?.nickname ?? '无主'} · 守卫 ${t.guard}${t.frozen ? ' · 已冻结' : ''}`}</title>
                </path>
              );
            })}
          {proj &&
            items.map((t) => {
              const [x, y] = proj(t.center.lng, t.center.lat);
              const sel = t.id === selectedId;
              const fs = 12 / Math.sqrt(view.s);
              const w = (t.name.length * 12 + 22) / Math.sqrt(view.s);
              return (
                <g key={`l${t.id}`} transform={`translate(${x} ${y})`} style={{ pointerEvents: 'none' }}>
                  <rect x={-w / 2} y={-fs} width={w} height={fs * 2} rx={fs} fill={sel ? '#141414' : '#fff'} stroke="#141414" strokeWidth={1} vectorEffect="non-scaling-stroke" />
                  <text textAnchor="middle" dominantBaseline="central" fontSize={fs} fontWeight={700} fill={sel ? '#fff' : '#141414'}>
                    {t.name}
                  </text>
                </g>
              );
            })}
        </g>
      </svg>
      {items.length === 0 && (
        <div style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#8a8a90', pointerEvents: 'none' }}>
          这个区域还没有领地
        </div>
      )}
      <div className="map-tools">
        <Tooltip title="放大" placement="left">
          <Button size="small" shape="circle" icon={<PlusOutlined />} onClick={() => zoom(1.4)} />
        </Tooltip>
        <Tooltip title="缩小" placement="left">
          <Button size="small" shape="circle" icon={<MinusOutlined />} onClick={() => zoom(1 / 1.4)} />
        </Tooltip>
        <Tooltip title="复位" placement="left">
          <Button size="small" shape="circle" icon={<AimOutlined />} onClick={() => setView({ s: 1, tx: 0, ty: 0 })} />
        </Tooltip>
      </div>
      <div className="map-legend">
        {owners.map(([name, color]) => (
          <span key={name}>
            <span className="swatch" style={{ background: color }} />
            {name}
          </span>
        ))}
        <span>
          <span className="swatch" style={{ background: 'transparent', border: '1.5px dashed #2F6FD0' }} />
          已冻结
        </span>
        <span className="muted">无底图示意</span>
      </div>
    </div>
  );
}
