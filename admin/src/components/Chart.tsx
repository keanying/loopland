import ReactEChartsCore from 'echarts-for-react/lib/core';
import * as echarts from 'echarts/core';
import { LineChart, BarChart } from 'echarts/charts';
import { GridComponent, MarkLineComponent, TooltipComponent, MarkPointComponent, LegendComponent } from 'echarts/components';
import { SVGRenderer } from 'echarts/renderers';
import type { EChartsOption } from 'echarts';
import type { CSSProperties } from 'react';

echarts.use([LineChart, BarChart, GridComponent, TooltipComponent, MarkLineComponent, MarkPointComponent, LegendComponent, SVGRenderer]);

export default function Chart({ option, style }: { option: EChartsOption; style?: CSSProperties }) {
  return <ReactEChartsCore echarts={echarts} option={{ animationDuration: 400, ...option }} notMerge lazyUpdate opts={{ renderer: 'svg' }} style={style ?? { height: 280 }} />;
}
