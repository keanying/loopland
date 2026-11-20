import type { ThemeConfig } from 'antd';

export const BRAND = {
  night: '#0E0E10',
  ink: '#141414',
  lime: '#DCF26A',
  lavender: '#B4A3F5',
  canvas: '#E9E9EB',
  card: '#F2F2F4',
  line: '#E2E2E6',
  muted: '#8A8A90',
  red: '#D93A2B',
  green: '#3D8B2F',
};

export const theme: ThemeConfig = {
  token: {
    colorPrimary: BRAND.ink,
    colorInfo: '#7B6AE0',
    colorLink: BRAND.ink,
    colorSuccess: '#52A43A',
    colorError: BRAND.red,
    colorWarning: '#D99A0B',
    colorText: BRAND.ink,
    colorBorder: BRAND.line,
    colorBgLayout: BRAND.canvas,
    borderRadius: 12,
    borderRadiusLG: 20,
    controlHeight: 36,
    fontFamily:
      "-apple-system, BlinkMacSystemFont, 'PingFang SC', 'Noto Sans SC', 'Microsoft YaHei', 'Helvetica Neue', Arial, sans-serif",
  },
  components: {
    Button: { primaryShadow: 'none', defaultShadow: 'none', dangerShadow: 'none', borderRadius: 999, borderRadiusLG: 999, borderRadiusSM: 999, fontWeight: 600 },
    Segmented: { itemSelectedBg: BRAND.ink, itemSelectedColor: '#FFFFFF', trackBg: BRAND.card, borderRadius: 999, borderRadiusSM: 999, borderRadiusXS: 999, borderRadiusLG: 999, trackPadding: 4 },
    Table: { headerBg: 'transparent', headerColor: BRAND.muted, headerSplitColor: 'transparent', rowHoverBg: '#F7F7F8', cellPaddingBlock: 12 },
    Tag: { borderRadiusSM: 999 },
    Drawer: { paddingLG: 24 },
    Switch: { colorPrimary: BRAND.ink, colorPrimaryHover: '#2E2E33' },
    Slider: { handleColor: BRAND.ink, trackBg: BRAND.ink, trackHoverBg: '#2E2E33', handleActiveColor: BRAND.ink, dotActiveBorderColor: BRAND.ink },
    Input: { borderRadius: 12 },
    InputNumber: { borderRadius: 12 },
    Select: { borderRadius: 12 },
    Card: { borderRadiusLG: 24 },
  },
};
