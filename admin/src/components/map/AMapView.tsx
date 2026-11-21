import { useEffect, useRef, useState } from 'react';
import { Alert } from 'antd';
import { bossColor, bossKindName } from '../../utils/gameplay';
import { config } from '../../config';
import { ALL_LAYERS, CHEST_COLOR, hpColor, ownerColor, rings, routeColor, routesOf, type MapProps } from './colors';

// Minimal typings for the parts of AMap JS API 2.0 we use.
interface LngLatLike {
  lng: number;
  lat: number;
}
interface AMapBounds {
  getSouthWest(): LngLatLike;
  getNorthEast(): LngLatLike;
}
interface AMapEvent {
  lnglat?: { getLng(): number; getLat(): number };
}
interface AMapMap {
  add(o: unknown): void;
  remove(o: unknown): void;
  on(ev: string, fn: (e: AMapEvent) => void): void;
  getBounds(): AMapBounds;
  setZoomAndCenter(zoom: number, center: [number, number]): void;
  setFitView(overlays?: unknown[]): void;
  setDefaultCursor(cursor: string): void;
  destroy(): void;
}
interface AMapOverlay {
  on(ev: string, fn: (e: AMapEvent) => void): void;
}
type Ctor = new (opts: Record<string, unknown>) => AMapOverlay;
interface AMapNS {
  Map: new (el: HTMLElement, opts: Record<string, unknown>) => AMapMap;
  Polygon: Ctor;
  Circle: Ctor;
  Marker: Ctor;
  Polyline: Ctor;
}

declare global {
  interface Window {
    _AMapSecurityConfig?: { securityJsCode?: string; serviceHost?: string };
  }
}

async function loadAMap(): Promise<AMapNS> {
  const { key, security_code, service_host, version } = config.amap;
  if (service_host) window._AMapSecurityConfig = { serviceHost: service_host };
  else if (security_code) window._AMapSecurityConfig = { securityJsCode: security_code };
  const loader = await import('@amap/amap-jsapi-loader');
  const load = loader.load ?? (loader as unknown as { default: { load: typeof loader.load } }).default.load;
  return (await load({ key, version })) as AMapNS;
}

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

/** AMap (高德) JS API 2.0 map. Only used when amap.key is set in config.yaml. */
export default function AMapView({
  items,
  selectedId,
  onSelect,
  focus,
  onBounds,
  objects,
  layers = ALL_LAYERS,
  selectedObject,
  onSelectObject,
  picking,
  onPick,
  pickPoint,
  onViewport,
}: MapProps) {
  const el = useRef<HTMLDivElement | null>(null);
  const [ns, setNs] = useState<AMapNS | null>(null);
  const map = useRef<AMapMap | null>(null);
  const overlays = useRef<AMapOverlay[]>([]);
  const objOverlays = useRef<AMapOverlay[]>([]);
  const pickOverlay = useRef<AMapOverlay | null>(null);
  const fitted = useRef(false);
  const [err, setErr] = useState<string | null>(null);
  const cb = useRef({ onSelect, onBounds, onSelectObject, onPick, onViewport, picking });
  cb.current = { onSelect, onBounds, onSelectObject, onPick, onViewport, picking };

  /** In pick mode any click (map or overlay) reports its coordinate. */
  const pickFrom = (e: AMapEvent): boolean => {
    if (!cb.current.picking || !e.lnglat) return false;
    cb.current.onPick?.({ lat: +e.lnglat.getLat().toFixed(6), lng: +e.lnglat.getLng().toFixed(6) });
    return true;
  };

  useEffect(() => {
    if (!config.amap.key || !el.current) return;
    let alive = true;
    loadAMap()
      .then((A) => {
        if (!alive || !el.current) return;
        const m = new A.Map(el.current, { zoom: 14, viewMode: '2D', mapStyle: config.amap.map_style });
        const report = () => {
          const b = m.getBounds();
          const sw = b.getSouthWest();
          const ne = b.getNorthEast();
          const box: [number, number, number, number] = [sw.lng, sw.lat, ne.lng, ne.lat];
          cb.current.onBounds?.(box);
          cb.current.onViewport?.(box);
        };
        m.on('moveend', report);
        m.on('complete', report);
        m.on('click', (e) => pickFrom(e));
        map.current = m;
        setNs(A);
      })
      .catch((e: unknown) => setErr(e instanceof Error ? e.message : String(e)));
    return () => {
      alive = false;
      map.current?.destroy();
      map.current = null;
    };
  }, []);

  useEffect(() => {
    map.current?.setDefaultCursor(picking ? 'crosshair' : 'default');
  }, [picking, ns]);

  useEffect(() => {
    const m = map.current;
    if (!ns || !m) return;
    for (const o of overlays.current) m.remove(o);
    overlays.current = (layers.territories ? items : []).map((t) => {
      const sel = t.id === selectedId;
      const p = new ns.Polygon({
        path: rings(t).map((r) => r.map(([lng, lat]) => [lng, lat])),
        fillColor: ownerColor(t.owner?.id),
        fillOpacity: sel ? 0.75 : 0.5,
        strokeColor: t.frozen ? '#2F6FD0' : sel ? '#141414' : '#3a3a40',
        strokeWeight: sel ? 3 : 1.4,
        strokeStyle: t.frozen ? 'dashed' : 'solid',
        cursor: 'pointer',
        extData: t.id,
      });
      p.on('click', (e) => pickFrom(e) || cb.current.onSelect(t.id));
      m.add(p);
      return p;
    });
    if (!fitted.current && overlays.current.length) {
      m.setFitView(overlays.current);
      fitted.current = true;
    }
  }, [ns, items, selectedId, layers.territories]);

  useEffect(() => {
    const m = map.current;
    if (!ns || !m) return;
    for (const o of objOverlays.current) m.remove(o);
    const out: AMapOverlay[] = [];
    if (layers.bosses) {
      for (const b of objects?.bosses ?? []) {
        const sel = selectedObject?.type === 'boss' && selectedObject.id === b.id;
        const circle = new ns.Circle({
          center: [b.center.lng, b.center.lat],
          radius: b.radius_m,
          fillColor: bossColor(b.kind),
          fillOpacity: 0.16,
          strokeColor: sel ? '#141414' : '#D93A2B',
          strokeWeight: sel ? 2.5 : 1.5,
          strokeStyle: 'dashed',
          bubble: true,
        });
        circle.on('click', (e) => pickFrom(e));
        const ratio = b.hp_max > 0 ? Math.max(0, Math.min(1, b.hp / b.hp_max)) : 0;
        const marker = new ns.Marker({
          position: [b.center.lng, b.center.lat],
          anchor: 'bottom-center',
          offset: [0, 16],
          zIndex: 120,
          content:
            `<div class="amap-boss${sel ? ' sel' : ''}">` +
            `<div class="amap-boss-label">${esc(b.name || bossKindName(b.kind))} Lv.${b.level}` +
            `<div class="amap-boss-hp"><i style="width:${(ratio * 100).toFixed(1)}%;background:${hpColor(b.hp, b.hp_max)}"></i></div></div>` +
            `<div class="amap-boss-dot" style="background:${bossColor(b.kind)}">${esc(bossKindName(b.kind, b.name).slice(0, 1))}</div></div>`,
          title: `${b.location_name} · HP ${b.hp}/${b.hp_max}`,
        });
        marker.on('click', (e) => pickFrom(e) || cb.current.onSelectObject?.({ type: 'boss', id: b.id }));
        out.push(circle, marker);
      }
    }
    if (layers.chests) {
      for (const c of objects?.chests ?? []) {
        const sel = selectedObject?.type === 'chest' && selectedObject.id === c.id;
        const marker = new ns.Marker({
          position: [c.center.lng, c.center.lat],
          anchor: 'center',
          zIndex: 110,
          content: `<div class="amap-chest${sel ? ' sel' : ''}" style="background:${CHEST_COLOR}"></div>`,
          title: `宝箱 #${c.id}`,
        });
        marker.on('click', (e) => pickFrom(e) || cb.current.onSelectObject?.({ type: 'chest', id: c.id }));
        out.push(marker);
      }
    }
    if (layers.checkpoints) {
      for (const [rid, cps] of routesOf(objects)) {
        const color = routeColor(rid);
        out.push(new ns.Polyline({ path: cps.map((c) => [c.center.lng, c.center.lat]), strokeColor: color, strokeWeight: 3, strokeStyle: 'dashed', strokeDasharray: [4, 8], bubble: true }));
        for (const c of cps) {
          out.push(new ns.Circle({ center: [c.center.lng, c.center.lat], radius: c.radius_m, fillColor: color, fillOpacity: 0.12, strokeWeight: 0, bubble: true }));
          out.push(
            new ns.Marker({
              position: [c.center.lng, c.center.lat],
              anchor: 'center',
              zIndex: 105,
              content: `<div class="amap-cp" style="border-color:${color};color:${color}">${c.index + 1}</div>`,
              title: `定向打卡点 ${c.index + 1} · ${c.name}`,
            }),
          );
        }
      }
    }
    for (const o of out) m.add(o);
    objOverlays.current = out;
  }, [ns, objects, layers.bosses, layers.chests, layers.checkpoints, selectedObject]);

  useEffect(() => {
    const m = map.current;
    if (!ns || !m) return;
    if (pickOverlay.current) m.remove(pickOverlay.current);
    pickOverlay.current = null;
    if (pickPoint) {
      pickOverlay.current = new ns.Marker({ position: [pickPoint.lng, pickPoint.lat], anchor: 'center', zIndex: 200, content: '<div class="amap-pick"></div>' });
      m.add(pickOverlay.current);
    }
  }, [ns, pickPoint]);

  useEffect(() => {
    if (focus && map.current) map.current.setZoomAndCenter(16, [focus.lng, focus.lat]);
  }, [focus]);

  return (
    <div className="map-wrap">
      {err && <Alert type="error" showIcon message={`高德地图加载失败：${err}`} style={{ position: 'absolute', zIndex: 2, left: 12, top: 12 }} />}
      <div ref={el} style={{ width: '100%', height: '100%' }} />
    </div>
  );
}
