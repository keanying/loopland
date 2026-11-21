import type { LatLng, MapObjects, TerritorySummary } from '../../api/types';

const PALETTE = ['#B4A3F5', '#DCF26A', '#F59E5B', '#7CC6F2', '#F27CA8', '#8DD98B', '#F2C94C', '#9AA0FF', '#5ED3C4', '#E58C8C'];
export const UNOWNED = '#D6D6DA';

/** Admin map colours territories by owner (the API fixes relation to unowned/enemy). */
export function ownerColor(ownerId: number | null | undefined): string {
  if (ownerId === null || ownerId === undefined) return UNOWNED;
  return PALETTE[Math.abs(ownerId * 2654435761) % PALETTE.length];
}

export function rings(t: Pick<TerritorySummary, 'geometry'>): number[][][] {
  const g = t.geometry;
  if (!g) return [];
  if (g.type === 'Polygon') return g.coordinates;
  return g.coordinates.flat();
}

export interface MapProps {
  items: TerritorySummary[];
  selectedId: number | null;
  onSelect: (id: number) => void;
  /** Center on this point; `n` changes to re-trigger the same point. */
  focus: { lat: number; lng: number; n: number } | null;
  onBounds?: (bbox: [number, number, number, number]) => void;
  // ---- V2: gameplay objects (GET /admin/v1/map/objects) ----
  objects?: MapObjects | null;
  layers?: MapLayers;
  selectedObject?: MapObjectRef | null;
  onSelectObject?: (o: MapObjectRef) => void;
  /** While true, a click on the map reports its coordinate through onPick instead of selecting. */
  picking?: boolean;
  onPick?: (p: LatLng) => void;
  /** Marker for a coordinate being entered in a form. */
  pickPoint?: LatLng | null;
  /** Visible area as minLng,minLat,maxLng,maxLat (SVG: after pan/zoom; AMap: the viewport). */
  onViewport?: (bbox: [number, number, number, number]) => void;
}

export interface MapLayers {
  territories: boolean;
  bosses: boolean;
  chests: boolean;
  checkpoints: boolean;
  /** V2 第四批 补给站 (shown unless false). */
  supplies?: boolean;
}

export const ALL_LAYERS: MapLayers = { territories: true, bosses: true, chests: true, checkpoints: true, supplies: true };

export type MapObjectRef = { type: 'boss' | 'chest'; id: number };

export const CHEST_COLOR = '#F2C94C';
export const SUPPLY_COLOR = '#3D8B2F';
const ROUTE_COLORS = ['#2F6FD0', '#3D8B2F', '#D93A2B', '#7B6AE0', '#D99A0B'];
export const routeColor = (routeId: number) => ROUTE_COLORS[Math.abs(routeId) % ROUTE_COLORS.length];

export function hpColor(hp: number, max: number): string {
  const r = max > 0 ? hp / max : 0;
  return r < 0.25 ? '#D93A2B' : r < 0.6 ? '#D99A0B' : '#3D8B2F';
}

/** Checkpoints grouped per route, in visiting order. */
export function routesOf(objects: MapObjects | null | undefined): Map<number, MapObjects['checkpoints']> {
  const m = new Map<number, MapObjects['checkpoints']>();
  for (const c of objects?.checkpoints ?? []) {
    const arr = m.get(c.route_id) ?? [];
    arr.push(c);
    m.set(c.route_id, arr);
  }
  for (const arr of m.values()) arr.sort((a, b) => a.index - b.index);
  return m;
}
