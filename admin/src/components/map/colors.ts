import type { TerritorySummary } from '../../api/types';

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
}
