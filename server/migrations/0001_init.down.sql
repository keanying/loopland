DROP TABLE IF EXISTS audit_logs, admin_users, settings, gameplay_configs, notifications,
  memberships, orders, plans, risk_alerts, codex_items, territory_stationed, territory_buildings,
  territory_events, territories, user_sport_totals, track_points, activities, energy_ledger,
  crew_applications, crew_members, crews, user_devices, refresh_tokens, user_identities, users CASCADE;
DROP FUNCTION IF EXISTS lp_clean(geometry);
DROP FUNCTION IF EXISTS lp_area(geometry);
