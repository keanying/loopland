import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { App, Button, Form, Input, Modal, Select, Space, Switch, Table, Tag } from 'antd';
import { api } from '../api/admin';
import type { AdminAccount, AdminCreate, AdminPatch, AdminRole } from '../api/types';
import { useAuth } from '../auth/AuthContext';
import { PageHeader, Panel } from '../components/ui';
import { dt } from '../utils/format';
import { ROLE_LABEL } from '../utils/labels';
import { toastOk } from '../utils/notify';
import { Glyph } from '../components/Glyph';

const ROLE_OPTIONS = (Object.keys(ROLE_LABEL) as AdminRole[]).map((r) => ({ value: r, label: ROLE_LABEL[r] }));
const ROLE_HINT: Record<AdminRole, string> = {
  admin: '全部权限，含发布玩法配置、退款、管理后台账号',
  ops: '用户、套餐、领地、风控处置与规则',
  reviewer: '风控告警处理、查看用户',
  merchant: '商户与活动（V2），V1 只读',
};

export default function AdminsPage() {
  const { modal } = App.useApp();
  const { admin: me } = useAuth();
  const qc = useQueryClient();
  const list = useQuery({ queryKey: ['admins'], queryFn: api.admins });
  const [creating, setCreating] = useState(false);
  const [pwFor, setPwFor] = useState<AdminAccount | null>(null);
  const [createForm] = Form.useForm<AdminCreate>();
  const [pwForm] = Form.useForm<{ password: string }>();

  const create = useMutation({
    mutationFn: (b: AdminCreate) => api.createAdmin(b),
    onSuccess: (a) => {
      qc.invalidateQueries({ queryKey: ['admins'] });
      setCreating(false);
      createForm.resetFields();
      toastOk(`已创建账号 ${a.username}`);
    },
  });
  const patch = useMutation({
    mutationFn: ({ id, body }: { id: number; body: AdminPatch }) => api.patchAdmin(id, body),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['admins'] });
      toastOk('已更新');
    },
  });

  return (
    <>
      <PageHeader
        title="后台账号"
        sub="四种角色：管理员、运营、审核员、商户对接。只有管理员能发布玩法配置、退款、管理账号"
        extra={
          <Button type="primary" icon={<Glyph name="plus" />} onClick={() => setCreating(true)}>
            新建账号
          </Button>
        }
      />
      <Panel title="账号">
        <Table<AdminAccount>
          rowKey="id"
          loading={list.isFetching}
          dataSource={list.data?.items}
          pagination={false}
          scroll={{ x: 760 }}
          columns={[
            {
              title: '用户名',
              dataIndex: 'username',
              render: (v: string, r) => (
                <Space>
                  <b>{v}</b>
                  {r.id === me?.id && <Tag bordered={false}>我</Tag>}
                </Space>
              ),
            },
            {
              title: '角色',
              dataIndex: 'role',
              render: (v: AdminRole, r) => (
                <Select
                  size="small"
                  style={{ width: 120 }}
                  value={v}
                  options={ROLE_OPTIONS}
                  disabled={r.id === me?.id}
                  onChange={(role) =>
                    modal.confirm({
                      title: `把 ${r.username} 改为「${ROLE_LABEL[role]}」？`,
                      content: ROLE_HINT[role],
                      okText: '确认',
                      cancelText: '取消',
                      onOk: () => patch.mutateAsync({ id: r.id, body: { role } }),
                    })
                  }
                />
              ),
            },
            {
              title: '启用',
              dataIndex: 'disabled',
              render: (v: boolean, r) => (
                <Switch
                  size="small"
                  checked={!v}
                  disabled={r.id === me?.id}
                  onChange={(on) =>
                    modal.confirm({
                      title: on ? `启用 ${r.username}？` : `停用 ${r.username}？`,
                      content: on ? '启用后可以重新登录。' : '停用后该账号立即无法登录。',
                      okText: '确认',
                      okButtonProps: { danger: !on },
                      cancelText: '取消',
                      onOk: () => patch.mutateAsync({ id: r.id, body: { disabled: !on } }),
                    })
                  }
                />
              ),
            },
            { title: '创建时间', dataIndex: 'created_at', render: (v: string) => <span className="num">{dt(v)}</span> },
            {
              title: '操作',
              key: 'op',
              align: 'right',
              render: (_, r) => (
                <Button size="small" onClick={() => setPwFor(r)}>
                  重置密码
                </Button>
              ),
            },
          ]}
        />
      </Panel>

      <Modal open={creating} title="新建后台账号" okText="创建" cancelText="取消" confirmLoading={create.isPending} onCancel={() => setCreating(false)} onOk={() => createForm.submit()} destroyOnHidden>
        <Form form={createForm} layout="vertical" requiredMark={false} initialValues={{ role: 'ops' }} onFinish={(v) => create.mutate(v)}>
          <Form.Item name="username" label="用户名" rules={[{ required: true, message: '请输入用户名' }, { pattern: /^[a-zA-Z0-9_.-]{3,32}$/, message: '3–32 位字母、数字、下划线' }]}>
            <Input autoComplete="off" />
          </Form.Item>
          <Form.Item name="password" label="初始密码" rules={[{ required: true, message: '请输入密码' }, { min: 8, message: '至少 8 位' }]}>
            <Input.Password autoComplete="new-password" />
          </Form.Item>
          <Form.Item name="role" label="角色" extra={<RoleHint form={createForm} />}>
            <Select options={ROLE_OPTIONS} />
          </Form.Item>
        </Form>
      </Modal>

      <Modal
        open={!!pwFor}
        title={`重置 ${pwFor?.username ?? ''} 的密码`}
        okText="重置"
        cancelText="取消"
        confirmLoading={patch.isPending}
        onCancel={() => setPwFor(null)}
        onOk={() => pwForm.submit()}
        destroyOnHidden
      >
        <Form
          form={pwForm}
          layout="vertical"
          requiredMark={false}
          onFinish={(v) => pwFor && patch.mutate({ id: pwFor.id, body: { password: v.password } }, { onSuccess: () => setPwFor(null) })}
        >
          <Form.Item name="password" label="新密码" rules={[{ required: true, message: '请输入新密码' }, { min: 8, message: '至少 8 位' }]}>
            <Input.Password autoComplete="new-password" />
          </Form.Item>
        </Form>
      </Modal>
    </>
  );
}

function RoleHint({ form }: { form: ReturnType<typeof Form.useForm<AdminCreate>>[0] }) {
  const role = Form.useWatch('role', form) as AdminRole | undefined;
  return <span>{role ? ROLE_HINT[role] : ''}</span>;
}
