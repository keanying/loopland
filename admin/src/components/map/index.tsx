import { config } from '../../config';
import AMapView from './AMapView';
import SvgMap from './SvgMap';
import type { MapProps } from './colors';

export const HAS_AMAP = !!config.amap.key;

export default function TerritoryMap(props: MapProps) {
  return HAS_AMAP ? <AMapView {...props} /> : <SvgMap {...props} />;
}
