import { useState } from 'react';
import { Navigate, useLocation, useNavigate } from 'react-router-dom';
import { Alert, Button, Form, Input } from 'antd';
import { LockOutlined, UserOutlined } from '@ant-design/icons';
import { useAuth } from '../auth/AuthContext';
import { MOCK } from '../config';
import { errorMessage } from '../utils/notify';
import Logo from '../components/Logo';

export default function LoginPage() {
  const { admin, login } = useAuth();
  const navigate = useNavigate();
  const loc = useLocation();
  const from = (loc.state as { from?: string } | null)?.from ?? '/';
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  if (admin) return <Navigate to={from} replace />;

  const onFinish = async (v: { username: string; password: string }) => {
    setBusy(true);
    setError(null);
    try {
      await login(v.username.trim(), v.password);
      navigate(from, { replace: true });
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="login-bg">
      <div className="login-card">
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 6 }}>
          <div style={{ background: '#141414', borderRadius: 16, padding: 4, display: 'flex' }}>
            <Logo size={44} />
          </div>
          <div>
            <div style={{ fontSize: 22, fontWeight: 900 }}>圈圈 Loopland</div>
            <div className="muted" style={{ fontSize: 13 }}>
              运营后台
            </div>
          </div>
        </div>
        <div style={{ height: 4, width: 64, background: '#DCF26A', borderRadius: 4, margin: '18px 0 24px' }} />
        {error && <Alert type="error" showIcon message={error} style={{ marginBottom: 16 }} />}
        <Form layout="vertical" requiredMark={false} onFinish={onFinish} initialValues={MOCK ? { username: 'admin', password: 'loopland' } : undefined}>
          <Form.Item name="username" label="用户名" rules={[{ required: true, message: '请输入用户名' }]}>
            <Input size="large" prefix={<UserOutlined />} autoComplete="username" placeholder="用户名" />
          </Form.Item>
          <Form.Item name="password" label="密码" rules={[{ required: true, message: '请输入密码' }]}>
            <Input.Password size="large" prefix={<LockOutlined />} autoComplete="current-password" placeholder="密码" />
          </Form.Item>
          <Button type="primary" htmlType="submit" size="large" block loading={busy} style={{ marginTop: 8 }}>
            登录
          </Button>
        </Form>
        {MOCK && (
          <Alert
            style={{ marginTop: 18 }}
            type="info"
            message="Mock 模式"
            description="账号 admin（管理员）/ xiaolin（运营）/ amei（审核员）/ shop（商户对接），密码任意。"
          />
        )}
      </div>
    </div>
  );
}
