import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { DatePicker, Empty, Select, Space, Table, Tag } from 'antd';
import type { Dayjs } from 'dayjs';
import { api } from '../../api/admin';
import type { LeagueRow } from '../../api/types';
import { Panel, Tile } from '../../components/ui';
import { area, dayjs, num } from '../../utils/format';
import { BRAND } from '../../theme';

// Fallback when GET /admin/v1/districts returns nothing (no crews yet): Shanghai's 16 districts.
const FALLBACK_DISTRICTS = ['浦东新区', '黄浦区', '徐汇区', '长宁区', '静安区', '普陀区', '虹口区', '杨浦区', '闵行区', '宝山区', '嘉定区', '金山区', '松江区', '青浦区', '奉贤区', '崇明区'];

const monday = (d: Dayjs) => d.subtract((d.day() + 6) % 7, 'day').startOf('day');

export default function LeagueTab() {
  const ds = useQuery({ queryKey: ['districts'], queryFn: api.districts, staleTime: 5 * 60_000 });
  const fromServer = (ds.data?.items ?? []).filter((d) => d.name);
  const options = fromServer.length
    ? fromServer.map((d) => ({ value: d.name, label: `${d.name} · ${d.crews} 个跑团` }))
    : FALLBACK_DISTRICTS.map((d) => ({ value: d, label: d }));
  const [picked, setDistrict] = useState<string | null>(null);
  const district = picked ?? options[0].value;
  const [week, setWeek] = useState<Dayjs>(() => monday(dayjs()));
  const weekStart = week.format('YYYY-MM-DD');
  const q = useQuery({
    queryKey: ['league', district, weekStart],
    queryFn: () => api.league({ district, week_start: weekStart }),
    // Wait for the district list so the first request uses its first entry, not the fallback.
    enabled: !ds.isPending,
    placeholderData: (p) => p,
  });
  const data = q.data;
  const rows = data?.standings ?? [];
  const current = monday(dayjs()).isSame(week, 'day');
  const total = rows.reduce((s, r) => s + r.score_m2, 0);

  return (
    <Panel
      title="城区联赛"
      extra={
        <Space wrap>
          <Select showSearch optionFilterProp="value" style={{ width: 190 }} value={district} options={options} loading={ds.isPending} onChange={setDistrict} aria-label="城区" />
          <DatePicker
            picker="week"
            value={week}
            allowClear={false}
            disabledDate={(d) => d.isAfter(dayjs(), 'day') && !monday(d).isSame(monday(dayjs()), 'day')}
            format={(d) => `${monday(d).format('YYYY-MM-DD')} 周`}
            onChange={(d) => d && setWeek(monday(d))}
            style={{ width: 170 }}
          />
        </Space>
      }
    >
      <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap', marginBottom: 14 }}>
        <div style={{ flex: '1 1 160px' }}>
          <Tile v={rows.length} l="参赛跑团" />
        </div>
        <div style={{ flex: '1 1 160px' }}>
          <Tile v={area(total)} l="本周新圈合计" />
        </div>
        <div style={{ flex: '1 1 160px' }}>
          <Tile v={num(rows.reduce((s, r) => s + r.active_members, 0))} l="活跃成员" />
        </div>
        <div style={{ flex: '2 1 240px' }}>
          <Tile
            v={<span style={{ fontSize: 16 }}>{data?.week_start ?? weekStart} 起</span>}
            l={current ? '本周进行中 · 下周一 00:00 结算' : `已于 ${dayjs(data?.week_start ?? weekStart).add(7, 'day').format('MM-DD')} 00:00 结算`}
          />
        </div>
      </div>
      <Table<LeagueRow>
        rowKey={(r) => r.crew.id}
        loading={q.isFetching || ds.isPending}
        dataSource={rows}
        pagination={false}
        locale={{ emptyText: <Empty description={`${district}这一周没有跑团参赛`} /> }}
        columns={[
          {
            title: '名次',
            dataIndex: 'rank',
            width: 80,
            render: (v: number) =>
              v <= 3 ? (
                <span className="num" style={{ display: 'inline-flex', width: 28, height: 28, borderRadius: 14, alignItems: 'center', justifyContent: 'center', fontWeight: 800, background: [BRAND.lime, '#E4E4E8', '#F4D9B8'][v - 1], border: '1.5px solid #141414' }}>
                  {v}
                </span>
              ) : (
                <span className="num muted" style={{ paddingLeft: 9 }}>
                  {v}
                </span>
              ),
          },
          {
            title: '跑团',
            key: 'crew',
            render: (_, r) => (
              <span>
                <b>{r.crew.name}</b> <span className="muted num">#{r.crew.id}</span>
                {r.rank === 1 && (
                  <Tag bordered={false} color="gold" style={{ marginLeft: 8 }}>
                    {current ? '暂列第一' : '本周冠军'}
                  </Tag>
                )}
              </span>
            ),
          },
          {
            title: '本周新圈面积',
            dataIndex: 'score_m2',
            align: 'right',
            render: (v: number) => (
              <div style={{ display: 'flex', alignItems: 'center', gap: 10, justifyContent: 'flex-end' }}>
                <div className="bar-track" style={{ width: 160 }}>
                  <div className="bar-fill" style={{ width: `${rows[0]?.score_m2 ? (v / rows[0].score_m2) * 100 : 0}%` }} />
                </div>
                <span className="num" style={{ width: 90 }}>
                  {area(v)}
                </span>
              </div>
            ),
          },
          { title: '活跃成员', dataIndex: 'active_members', align: 'right', render: (v: number) => <span className="num">{v} 人</span> },
        ]}
      />
    </Panel>
  );
}
