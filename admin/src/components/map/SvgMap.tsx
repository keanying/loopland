import { useEffect, useMemo, useRef, useState } from 'react';
import { Button, Tooltip } from 'antd';
import { AimOutlined, MinusOutlined, PlusOutlined } from '@ant-design/icons';
import type { MapCheckpoint } from '../../api/types';
import { bossKindName, bossColor } from '../../utils/gameplay';
import type { LatLng } from '../../api/types';
import { ALL_LAYERS, CHEST_COLOR, hpColor, ownerColor, rings, routeColor, routesOf, SUPPLY_COLOR, type MapProps } from './colors';

// Room for boss labels above and the legend below.
const PAD = { x: 40, top: 56, bottom: 76 };
const M_PER_DEG_LAT = 110_574;

interface View {
  s: number;
  tx: number;
  ty: number;
}

interface Projection {
  fwd: (lng: number, lat: number) => [number, number];
  inv: (x: number, y: number) => { lng: number; lat: number };
  /** SVG units per metre at zoom 1. */
  pxPerM: number;
}

/**
 * Fallback map used when no AMap key is configured: projects the GeoJSON
 * polygons (GCJ-02 lng/lat) onto an SVG with an equirectangular projection.
 * No basemap; wheel to zoom, drag to pan. Also draws the V2 gameplay objects
 * (bosses with their radius, chests, orienteering checkpoints).
 */
export default function SvgMap({
  items,
  selectedId,
  onSelect,
  focus,
  objects,
  layers = ALL_LAYERS,
  selectedObject,
  onSelectObject,
  picking,
  onPick,
  pickPoint,
  onViewport,
  preview,
  fallbackCenter,
  checkpointLabel = '定向打卡点',
}: MapProps & {
  preview?: boolean;
  /** Frame this point when there is nothing else to show (so a click can still pick). */
  fallbackCenter?: LatLng | null;
  /** Legend text for the checkpoint markers (e.g. a form's point being placed). */
  checkpointLabel?: string;
}) {
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

  const bosses = layers.bosses ? objects?.bosses ?? [] : [];
  const chests = layers.chests ? objects?.chests ?? [] : [];
  const supplies = layers.supplies !== false ? objects?.supplies ?? [] : [];
  const routes = useMemo(() => (layers.checkpoints ? routesOf(objects) : new Map<number, MapCheckpoint[]>()), [objects, layers.checkpoints]);
  const shownItems = layers.territories ? items : [];

  // Fit everything we know about (territories + objects) so objects never fall off-screen.
  const proj = useMemo<Projection | null>(() => {
    let minX = Infinity;
    let maxX = -Infinity;
    let minY = Infinity;
    let maxY = -Infinity;
    const add = (lng: number, lat: number) => {
      minX = Math.min(minX, lng);
      maxX = Math.max(maxX, lng);
      minY = Math.min(minY, lat);
      maxY = Math.max(maxY, lat);
    };
    for (const t of items) for (const r of rings(t)) for (const [lng, lat] of r) add(lng, lat);
    for (const b of objects?.bosses ?? []) {
      const d = b.radius_m / M_PER_DEG_LAT;
      add(b.center.lng - d, b.center.lat - d);
      add(b.center.lng + d, b.center.lat + d);
    }
    for (const c of objects?.chests ?? []) add(c.center.lng, c.center.lat);
    for (const c of objects?.checkpoints ?? []) add(c.center.lng, c.center.lat);
    for (const c of objects?.supplies ?? []) add(c.center.lng, c.center.lat);
    if (!Number.isFinite(minX) && fallbackCenter) {
      add(fallbackCenter.lng - 0.01, fallbackCenter.lat - 0.008);
      add(fallbackCenter.lng + 0.01, fallbackCenter.lat + 0.008);
    }
    if (!Number.isFinite(minX)) return null;
    const k = Math.cos((((minY + maxY) / 2) * Math.PI) / 180);
    const spanX = Math.max((maxX - minX) * k, 1e-6);
    const spanY = Math.max(maxY - minY, 1e-6);
    const scale = Math.min((W - PAD.x * 2) / spanX, (H - PAD.top - PAD.bottom) / spanY);
    const ox = (W - spanX * scale) / 2;
    const oy = PAD.top + (H - PAD.top - PAD.bottom - spanY * scale) / 2;
    return {
      fwd: (lng, lat) => [ox + (lng - minX) * k * scale, oy + (maxY - lat) * scale],
      inv: (x, y) => ({ lng: minX + (x - ox) / (k * scale), lat: maxY - (y - oy) / scale }),
      pxPerM: scale / M_PER_DEG_LAT,
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- the fallback only matters when it moves noticeably
  }, [items, objects, W, H, fallbackCenter ? `${fallbackCenter.lat.toFixed(2)},${fallbackCenter.lng.toFixed(2)}` : '']);

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
    const [x, y] = proj.fwd(focus.lng, focus.lat);
    const s = 2.4;
    setView({ s, tx: W / 2 - x * s, ty: H / 2 - y * s });
    // eslint-disable-next-line react-hooks/exhaustive-deps -- only re-center when asked
  }, [focus, proj]);

  /** Screen (viewBox) coordinate → lng/lat, undoing pan/zoom. */
  const toGeo = (sx: number, sy: number) => (proj ? proj.inv((sx - view.tx) / view.s, (sy - view.ty) / view.s) : null);

  // Report the visible area (debounced) so callers can e.g. scatter chests "in the current view".
  const vpCb = useRef(onViewport);
  vpCb.current = onViewport;
  useEffect(() => {
    if (!proj || !vpCb.current) return;
    const t = setTimeout(() => {
      const a = proj.inv((0 - view.tx) / view.s, (H - view.ty) / view.s);
      const b = proj.inv((W - view.tx) / view.s, (0 - view.ty) / view.s);
      vpCb.current?.([a.lng, a.lat, b.lng, b.lat]);
    }, 150);
    return () => clearTimeout(t);
  }, [proj, view, W, H]);

  const zoom = (f: number) =>
    setView((v) => {
      const s = Math.min(12, Math.max(0.6, v.s * f));
      return { s, tx: W / 2 - ((W / 2 - v.tx) / v.s) * s, ty: H / 2 - ((H / 2 - v.ty) / v.s) * s };
    });

  const owners = useMemo(() => {
    const m = new Map<string, string>();
    for (const t of items) {
      const name = t.owner ? t.owner.nickname : '无主';
      if (!m.has(name)) m.set(name, ownerColor(t.owner?.id));
    }
    return [...m.entries()].slice(0, 6);
  }, [items]);

  const z = 1 / Math.sqrt(view.s); // label size factor: grows slower than the map
  const moved = () => !!drag.current?.moved;
  const empty = shownItems.length === 0 && bosses.length === 0 && chests.length === 0 && routes.size === 0 && supplies.length === 0;

  return (
    <div className="map-wrap" ref={wrapRef}>
      <svg
        ref={svgRef}
        viewBox={`0 0 ${W} ${H}`}
        width="100%"
        height="100%"
        preserveAspectRatio="none"
        style={{ display: 'block', position: 'absolute', inset: 0, cursor: picking ? 'crosshair' : 'grab', touchAction: 'none' }}
        role="img"
        aria-label="领地与玩法对象分布示意图"
        onPointerDown={(e) => {
          drag.current = { x: e.clientX, y: e.clientY, tx: view.tx, ty: view.ty, moved: false };
        }}
        onPointerMove={(e) => {
          const d = drag.current;
          if (!d) return;
          const dx = e.clientX - d.x;
          const dy = e.clientY - d.y;
          if (Math.abs(dx) + Math.abs(dy) > 3) d.moved = true;
          if (d.moved) setView((v) => ({ ...v, tx: d.tx + dx, ty: d.ty + dy }));
        }}
        onPointerUp={() => {
          setTimeout(() => (drag.current = null), 0);
        }}
        onPointerLeave={() => (drag.current = null)}
        onClick={(e) => {
          if (!picking || !onPick || moved() || !svgRef.current) return;
          const rect = svgRef.current.getBoundingClientRect();
          const p = toGeo(((e.clientX - rect.left) / rect.width) * W, ((e.clientY - rect.top) / rect.height) * H);
          if (p) onPick({ lat: +p.lat.toFixed(6), lng: +p.lng.toFixed(6) });
        }}
      >
        <defs>
          <pattern id="grid" width="50" height="50" patternUnits="userSpaceOnUse">
            <path d="M 50 0 L 0 0 0 50" fill="none" stroke="#e4dccb" strokeWidth="1" />
          </pattern>
        </defs>
        <rect x={-W} y={-H} width={W * 3} height={H * 3} fill="url(#grid)" />
        <g transform={`translate(${view.tx} ${view.ty}) scale(${view.s})`}>
          {proj &&
            shownItems.map((t) => {
              const sel = t.id === selectedId;
              const color = ownerColor(t.owner?.id);
              const d = rings(t)
                .map((r) => r.map(([lng, lat], i) => `${i ? 'L' : 'M'}${proj.fwd(lng, lat).map((n) => n.toFixed(1)).join(' ')}`).join(' ') + ' Z')
                .join(' ');
              return (
                <path
                  key={t.id}
                  d={d}
                  fill={color}
                  fillOpacity={preview ? 0.22 : sel ? 0.75 : 0.5}
                  fillRule="evenodd"
                  stroke={t.frozen ? '#2F6FD0' : sel ? '#141414' : '#3a3a40'}
                  strokeWidth={sel ? 3 : 1.4}
                  strokeDasharray={t.frozen ? '6 4' : undefined}
                  vectorEffect="non-scaling-stroke"
                  style={{ cursor: picking ? 'crosshair' : 'pointer' }}
                  onClick={() => !picking && !moved() && onSelect(t.id)}
                >
                  <title>{`${t.name} · ${t.owner?.nickname ?? '无主'} · 守卫 ${t.guard}${t.frozen ? ' · 已冻结' : ''}`}</title>
                </path>
              );
            })}

          {/* boss ranges */}
          {proj &&
            bosses.map((b) => {
              const [x, y] = proj.fwd(b.center.lng, b.center.lat);
              const sel = selectedObject?.type === 'boss' && selectedObject.id === b.id;
              return (
                <circle
                  key={`br${b.id}`}
                  cx={x}
                  cy={y}
                  r={b.radius_m * proj.pxPerM}
                  fill={bossColor(b.kind)}
                  fillOpacity={0.16}
                  stroke={sel ? '#141414' : '#D93A2B'}
                  strokeWidth={sel ? 2.5 : 1.5}
                  strokeDasharray="8 5"
                  vectorEffect="non-scaling-stroke"
                  style={{ pointerEvents: 'none' }}
                />
              );
            })}

          {/* orienteering routes */}
          {proj &&
            [...routes.entries()].map(([rid, cps]) => (
              <polyline
                key={`rl${rid}`}
                points={cps.map((c) => proj.fwd(c.center.lng, c.center.lat).map((n) => n.toFixed(1)).join(',')).join(' ')}
                fill="none"
                stroke={routeColor(rid)}
                strokeWidth={2}
                strokeDasharray="2 6"
                strokeLinecap="round"
                vectorEffect="non-scaling-stroke"
                style={{ pointerEvents: 'none' }}
              />
            ))}

          {proj &&
            !preview &&
            shownItems.map((t) => {
              const [x, y] = proj.fwd(t.center.lng, t.center.lat);
              const sel = t.id === selectedId;
              const fs = 12 * z;
              const w = (t.name.length * 12 + 22) * z;
              return (
                <g key={`l${t.id}`} transform={`translate(${x} ${y})`} style={{ pointerEvents: 'none' }}>
                  <rect x={-w / 2} y={-fs} width={w} height={fs * 2} rx={fs} fill={sel ? '#141414' : '#fff'} stroke="#141414" strokeWidth={1} vectorEffect="non-scaling-stroke" />
                  <text textAnchor="middle" dominantBaseline="central" fontSize={fs} fontWeight={700} fill={sel ? '#fff' : '#141414'}>
                    {t.name}
                  </text>
                </g>
              );
            })}

          {/* checkpoints */}
          {proj &&
            [...routes.entries()].flatMap(([rid, cps]) =>
              cps.map((c) => {
                const [x, y] = proj.fwd(c.center.lng, c.center.lat);
                const r = 9 * z;
                return (
                  <g key={`cp${rid}-${c.index}`} transform={`translate(${x} ${y})`} style={{ pointerEvents: picking ? 'none' : 'auto' }}>
                    <circle r={Math.max(r, c.radius_m * proj.pxPerM)} fill={routeColor(rid)} fillOpacity={0.12} stroke="none" />
                    <circle r={r} fill="#fff" stroke={routeColor(rid)} strokeWidth={2} vectorEffect="non-scaling-stroke" />
                    <text textAnchor="middle" dominantBaseline="central" fontSize={10 * z} fontWeight={800} fill={routeColor(rid)}>
                      {c.index + 1}
                    </text>
                    {preview && (
                      <text x={r + 4 * z} y={0} dominantBaseline="central" fontSize={11 * z} fontWeight={700} fill="#141414" stroke="#fff" strokeWidth={3 * z} paintOrder="stroke">
                        {c.name}
                      </text>
                    )}
                    <title>{`定向打卡点 ${c.index + 1} · ${c.name} · 半径 ${c.radius_m} m（路线 #${rid}）`}</title>
                  </g>
                );
              }),
            )}

          {/* 补给站 (V2 第四批): range circle + cup marker */}
          {proj &&
            supplies.map((c) => {
              const [x, y] = proj.fwd(c.center.lng, c.center.lat);
              const r = 9 * z;
              return (
                <g key={`sp${c.id}`} transform={`translate(${x} ${y})`} style={{ pointerEvents: picking ? 'none' : 'auto' }}>
                  <circle r={Math.max(r, c.radius_m * proj.pxPerM)} fill={SUPPLY_COLOR} fillOpacity={0.12} stroke={SUPPLY_COLOR} strokeWidth={1} strokeDasharray="4 3" vectorEffect="non-scaling-stroke" />
                  <circle r={r} fill="#141414" stroke="#fff" strokeWidth={1.5} vectorEffect="non-scaling-stroke" />
                  <path d={`M ${-4 * z} ${-3 * z} h ${7 * z} v ${4 * z} a ${3 * z} ${3 * z} 0 0 1 ${-3 * z} ${3 * z} h ${-1 * z} a ${3 * z} ${3 * z} 0 0 1 ${-3 * z} ${-3 * z} z M ${3 * z} ${-2 * z} h ${1.5 * z} a ${1.5 * z} ${1.5 * z} 0 0 1 0 ${3 * z} h ${-1.5 * z}`} fill="none" stroke="#DCF26A" strokeWidth={1.4} vectorEffect="non-scaling-stroke" />
                  {preview && (
                    <text x={r + 4 * z} y={0} dominantBaseline="central" fontSize={11 * z} fontWeight={700} fill="#141414" stroke="#fff" strokeWidth={3 * z} paintOrder="stroke">
                      {c.name}
                    </text>
                  )}
                  <title>{`${c.name} · ${c.perk_title} · 半径 ${c.radius_m} m`}</title>
                </g>
              );
            })}

          {/* chests */}
          {proj &&
            chests.map((c) => {
              const [x, y] = proj.fwd(c.center.lng, c.center.lat);
              const s = 13 * z;
              const sel = selectedObject?.type === 'chest' && selectedObject.id === c.id;
              return (
                <g
                  key={`ch${c.id}`}
                  transform={`translate(${x} ${y})`}
                  style={{ cursor: picking ? 'crosshair' : 'pointer', pointerEvents: picking ? 'none' : 'auto' }}
                  onClick={(e) => {
                    e.stopPropagation();
                    if (!moved()) onSelectObject?.({ type: 'chest', id: c.id });
                  }}
                >
                  <rect x={-s / 2} y={-s / 2} width={s} height={s} rx={3 * z} fill={CHEST_COLOR} stroke="#141414" strokeWidth={sel ? 2.5 : 1.2} vectorEffect="non-scaling-stroke" />
                  <line x1={-s / 2} x2={s / 2} y1={-s * 0.1} y2={-s * 0.1} stroke="#141414" strokeWidth={1} vectorEffect="non-scaling-stroke" />
                  <title>{`宝箱 #${c.id} · 半径 ${c.radius_m} m`}</title>
                </g>
              );
            })}

          {/* boss markers + HP label */}
          {proj &&
            bosses.map((b) => {
              const [x, y] = proj.fwd(b.center.lng, b.center.lat);
              const r = 15 * z;
              const bw = 96 * z;
              const ratio = b.hp_max > 0 ? Math.max(0, Math.min(1, b.hp / b.hp_max)) : 0;
              const label = `${b.name || bossKindName(b.kind)} Lv.${b.level}`;
              const sel = selectedObject?.type === 'boss' && selectedObject.id === b.id;
              return (
                <g
                  key={`bm${b.id}`}
                  transform={`translate(${x} ${y})`}
                  style={{ cursor: picking ? 'crosshair' : 'pointer', pointerEvents: picking ? 'none' : 'auto' }}
                  onClick={(e) => {
                    e.stopPropagation();
                    if (!moved()) onSelectObject?.({ type: 'boss', id: b.id });
                  }}
                >
                  <circle r={r} fill={bossColor(b.kind)} stroke="#141414" strokeWidth={sel ? 3 : 1.8} vectorEffect="non-scaling-stroke" />
                  <text textAnchor="middle" dominantBaseline="central" fontSize={13 * z} fontWeight={900} fill="#141414">
                    {bossKindName(b.kind, b.name).slice(0, 1)}
                  </text>
                  <g transform={`translate(0 ${-r - 30 * z})`}>
                    <rect x={-bw / 2} y={0} width={bw} height={26 * z} rx={7 * z} fill="#141414" />
                    <text x={0} y={9 * z} textAnchor="middle" dominantBaseline="central" fontSize={10.5 * z} fontWeight={700} fill="#fff">
                      {label}
                    </text>
                    <rect x={-bw / 2 + 6 * z} y={17 * z} width={bw - 12 * z} height={5 * z} rx={2.5 * z} fill="#4a4a50" />
                    <rect x={-bw / 2 + 6 * z} y={17 * z} width={(bw - 12 * z) * ratio} height={5 * z} rx={2.5 * z} fill={hpColor(b.hp, b.hp_max)} />
                  </g>
                  <title>{`${label} · ${b.location_name} · HP ${b.hp}/${b.hp_max} · 半径 ${b.radius_m} m`}</title>
                </g>
              );
            })}

          {proj &&
            pickPoint &&
            (() => {
              const [x, y] = proj.fwd(pickPoint.lng, pickPoint.lat);
              const r = 10 * z;
              return (
                <g transform={`translate(${x} ${y})`} style={{ pointerEvents: 'none' }}>
                  <circle r={r} fill="none" stroke="#D93A2B" strokeWidth={2.5} vectorEffect="non-scaling-stroke" />
                  <line x1={-r * 1.8} x2={r * 1.8} y1={0} y2={0} stroke="#D93A2B" strokeWidth={1.5} vectorEffect="non-scaling-stroke" />
                  <line y1={-r * 1.8} y2={r * 1.8} x1={0} x2={0} stroke="#D93A2B" strokeWidth={1.5} vectorEffect="non-scaling-stroke" />
                </g>
              );
            })()}
        </g>
      </svg>
      {empty && (
        <div style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#8a8a90', pointerEvents: 'none' }}>
          这个区域还没有领地或玩法对象
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
        {layers.territories &&
          !preview &&
          owners.map(([name, color]) => (
            <span key={name}>
              <span className="swatch" style={{ background: color }} />
              {name}
            </span>
          ))}
        {layers.territories && !preview && (
          <span>
            <span className="swatch" style={{ background: 'transparent', border: '1.5px dashed #2F6FD0' }} />
            已冻结
          </span>
        )}
        {bosses.length > 0 && (
          <span>
            <span className="swatch" style={{ background: '#B4A3F5', borderRadius: '50%', border: '1.5px dashed #D93A2B' }} />
            怪兽范围
          </span>
        )}
        {chests.length > 0 && (
          <span>
            <span className="swatch" style={{ background: CHEST_COLOR }} />
            宝箱
          </span>
        )}
        {routes.size > 0 && (
          <span>
            <span className="swatch" style={{ background: '#fff', borderRadius: '50%', border: '2px solid #2F6FD0' }} />
            {checkpointLabel}
          </span>
        )}
        {supplies.length > 0 && (
          <span>
            <span className="swatch" style={{ background: '#141414', borderRadius: '50%', border: `2px solid ${SUPPLY_COLOR}` }} />
            补给站
          </span>
        )}
        {preview && <span className="muted">底色为附近领地</span>}
        <span className="muted">无底图示意</span>
      </div>
    </div>
  );
}
