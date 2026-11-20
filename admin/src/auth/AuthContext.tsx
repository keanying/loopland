import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { api } from '../api/admin';
import { getToken, onUnauthorized, setToken } from '../api/client';
import type { AdminMe } from '../api/types';
import { can, type Permission } from './permissions';

interface AuthState {
  admin: AdminMe | null;
  loading: boolean;
  login: (username: string, password: string) => Promise<void>;
  logout: () => void;
  can: (p: Permission) => boolean;
}

const Ctx = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const qc = useQueryClient();
  const [admin, setAdmin] = useState<AdminMe | null>(null);
  const [loading, setLoading] = useState<boolean>(() => !!getToken());

  const logout = useCallback(() => {
    setToken(null);
    setAdmin(null);
    qc.clear();
  }, [qc]);

  useEffect(() => {
    onUnauthorized(() => {
      setAdmin(null);
      qc.clear();
    });
    return () => onUnauthorized(null);
  }, [qc]);

  useEffect(() => {
    if (!getToken()) return;
    let alive = true;
    api
      .me()
      .then((me) => alive && setAdmin(me))
      .catch(() => alive && setToken(null))
      .finally(() => alive && setLoading(false));
    return () => {
      alive = false;
    };
  }, []);

  const login = useCallback(async (username: string, password: string) => {
    const res = await api.login({ username, password });
    setToken(res.token);
    setAdmin(res.admin);
  }, []);

  const value = useMemo<AuthState>(
    () => ({ admin, loading, login, logout, can: (p) => can(admin?.role, p) }),
    [admin, loading, login, logout],
  );
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

// eslint-disable-next-line react-refresh/only-export-components
export function useAuth(): AuthState {
  const v = useContext(Ctx);
  if (!v) throw new Error('useAuth outside AuthProvider');
  return v;
}
