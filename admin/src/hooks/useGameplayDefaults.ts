import { useQuery } from '@tanstack/react-query';
import { api } from '../api/admin';
import { useAuth } from '../auth/AuthContext';
import { BOSS_KIND } from '../utils/labels';

const BOSS_FALLBACK = { default_hp: 10000, radius_m: 1000, duration_h: 48 };
const CHEST_FALLBACK = { energy_min: 20, energy_max: 60, radius_m: 50, daily_spawn: 20, duration_h: 24 };

export function useGameplayDefaults() {
  const { can } = useAuth();
  const q = useQuery({ queryKey: ['gameplay'], queryFn: api.gameplay, enabled: can('gameplay.read'), staleTime: 60_000 });
  const body = q.data?.current.body;
  return {
    boss: { ...BOSS_FALLBACK, ...(body?.boss ?? {}) },
    chest: { ...CHEST_FALLBACK, ...(body?.chest ?? {}) },
    kinds: (body?.bosses?.length ? body.bosses.map((b) => ({ value: b.key, label: b.name })) : Object.entries(BOSS_KIND).map(([k, v]) => ({ value: k, label: v.name }))).filter(
      (k) => k.value in BOSS_KIND,
    ),
  };
}
