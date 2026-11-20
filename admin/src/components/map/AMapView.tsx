import { useEffect, useRef, useState } from 'react';
import { Alert } from 'antd';
import { ownerColor, rings, type MapProps } from './colors';

// Minimal typings for the parts of AMap JS API 2.0 we use.
interface LngLatLike {
  lng: number;
  lat: number;
}
interface AMapBounds {
  getSouthWest(): LngLatLike;
  getNorthEast(): LngLatLike;
}
interface AMapMap {
  add(o: unknown): void;
  remove(o: unknown): void;
  on(ev: string, fn: () => void): void;
  getBounds(): AMapBounds;
  setZoomAndCenter(zoom: number, center: [number, number]): void;
  setFitView(overlays?: unknown[]): void;
  destroy(): void;
}
interface AMapPolygon {
  on(ev: string, fn: () => void): void;
}
interface AMapNS {
  Map: new (el: HTMLElement, opts: Record<string, unknown>) => AMapMap;
  Polygon: new (opts: Record<string, unknown>) => AMapPolygon;
}

declare global {
  interface Window {
    _AMapSecurityConfig?: { securityJsCode: string };
  }
}

async function loadAMap(key: string): Promise<AMapNS> {
  const code = import.meta.env.VITE_AMAP_SECURITY_CODE;
  if (code) window._AMapSecurityConfig = { securityJsCode: code };
  const loader = await import('@amap/amap-jsapi-loader');
  const load = loader.load ?? (loader as unknown as { default: { load: typeof loader.load } }).default.load;
  return (await load({ key, version: '2.0' })) as AMapNS;
}

/** AMap (高德) JS API 2.0 map. Only used when VITE_AMAP_KEY is set. */
export default function AMapView({ items, selectedId, onSelect, focus, onBounds }: MapProps) {
  const el = useRef<HTMLDivElement | null>(null);
  const [ns, setNs] = useState<AMapNS | null>(null);
  const map = useRef<AMapMap | null>(null);
  const overlays = useRef<AMapPolygon[]>([]);
  const fitted = useRef(false);
  const [err, setErr] = useState<string | null>(null);
  const cb = useRef({ onSelect, onBounds });
  cb.current = { onSelect, onBounds };

  useEffect(() => {
    const key = import.meta.env.VITE_AMAP_KEY;
    if (!key || !el.current) return;
    let alive = true;
    loadAMap(key)
      .then((A) => {
        if (!alive || !el.current) return;
        const m = new A.Map(el.current, { zoom: 14, viewMode: '2D', mapStyle: 'amap://styles/whitesmoke' });
        m.on('moveend', () => {
          const b = m.getBounds();
          const sw = b.getSouthWest();
          const ne = b.getNorthEast();
          cb.current.onBounds?.([sw.lng, sw.lat, ne.lng, ne.lat]);
        });
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
    const m = map.current;
    if (!ns || !m) return;
    for (const o of overlays.current) m.remove(o);
    overlays.current = items.map((t) => {
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
      p.on('click', () => cb.current.onSelect(t.id));
      m.add(p);
      return p;
    });
    if (!fitted.current && overlays.current.length) {
      m.setFitView(overlays.current);
      fitted.current = true;
    }
  }, [ns, items, selectedId]);

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
