import { useEffect, useRef, useState } from 'react';
import { Navigate, useLocation, useNavigate } from 'react-router-dom';
import { Alert, Button, ConfigProvider, Form, Input } from 'antd';
import type { ThemeConfig } from 'antd';
import { useAuth } from '../auth/AuthContext';
import { MOCK } from '../config';
import { errorMessage } from '../utils/notify';
import Logo from '../components/Logo';
import { Glyph } from '../components/Glyph';
import { grainTile, startLoginScene } from '../components/loginScene';

// 登录卡片跟着版画背景用深蓝 + 米色，只在这一页生效。
const loginTheme: ThemeConfig = {
  token: { colorPrimary: '#1A338C', colorText: '#13286F', colorBorder: 'rgba(26, 51, 140, .3)', colorTextPlaceholder: 'rgba(26, 51, 140, .4)', borderRadius: 4 },
  components: {
    Button: { borderRadius: 4, borderRadiusLG: 4, primaryShadow: 'none' },
    Input: { borderRadius: 4, borderRadiusLG: 4, colorBgContainer: '#FBF5E4', activeShadow: '0 0 0 3px rgba(26, 51, 140, .14)' },
    Alert: { borderRadiusLG: 4 },
  },
};

/** Animated engraved landscape behind the login form. */
function LoginScene() {
  const canvas = useRef<HTMLCanvasElement>(null);
  const [grain] = useState(grainTile);
  const [on, setOn] = useState(false);
  useEffect(() => {
    const c = canvas.current;
    if (!c) return;
    const stop = startLoginScene(c);
    const raf = requestAnimationFrame(() => setOn(true));
    return () => {
      cancelAnimationFrame(raf);
      stop();
    };
  }, []);
  return (
    <>
      <canvas ref={canvas} className={on ? 'login-scene on' : 'login-scene'} aria-hidden="true" />
      <div className="login-grain" style={{ backgroundImage: `url(${grain})` }} />
    </>
  );
}

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
      <LoginScene />
      <main className="login-stage">
        <div className="login-wrap">
          <section className="login-pitch">
            <div className="login-mark">
              <Logo size={34} bg="#213E9F" ring="#F3E8CC" />
              圈圈 Loopland
            </div>
            <div className="login-eyebrow">运营后台</div>
            <h1>
              每一次运动，
              <br />
              都在地图上圈一圈。
            </h1>
            <p>和你的伙伴一起游戏，一起跑。领地、城区、怪兽和跑团，都在这里管理。</p>
          </section>
          <ConfigProvider theme={loginTheme}>
            <div className="login-card">
              <div className="login-head">
                <div className="login-tile">
                  <Logo size={40} bg="#1A338C" />
                </div>
                <div>
                  <b>圈圈 Loopland</b>
                  <span>运营后台</span>
                </div>
              </div>
              {error && <Alert type="error" showIcon message={error} style={{ marginBottom: 16 }} />}
              <Form layout="vertical" requiredMark={false} onFinish={onFinish} initialValues={MOCK ? { username: 'admin', password: 'loopland' } : undefined}>
                <Form.Item name="username" label="用户名" rules={[{ required: true, message: '请输入用户名' }]}>
                  <Input size="large" prefix={<Glyph name="user" />} autoComplete="username" placeholder="用户名" />
                </Form.Item>
                <Form.Item name="password" label="密码" rules={[{ required: true, message: '请输入密码' }]}>
                  <Input.Password size="large" prefix={<Glyph name="lock" />} autoComplete="current-password" placeholder="密码" />
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
          </ConfigProvider>
        </div>
      </main>
    </div>
  );
}
