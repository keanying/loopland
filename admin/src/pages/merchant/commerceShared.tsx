// Small shared components for V2 第五批「商户商品与开放平台」 (status tags, price).
import { Tag, Tooltip } from 'antd';
import type { EntryStatus, ProductOrderStatus, ProductStatus, PromotionStatus } from '../../api/commerce';
import { yuan } from '../../utils/format';
import { ENTRY_STATUS, ORDER_STATUS, PRODUCT_STATUS, PROMOTION_STATUS } from './commerceLabels';

export function ProductStatusTag({ status }: { status: ProductStatus }) {
  const s = PRODUCT_STATUS[status];
  return (
    <Tooltip title={s?.hint}>
      <Tag bordered={false} color={s?.color} style={{ marginInlineEnd: 0 }}>
        {s?.text ?? status}
      </Tag>
    </Tooltip>
  );
}

export function OrderStatusTag({ status }: { status: ProductOrderStatus }) {
  const s = ORDER_STATUS[status];
  return (
    <Tag bordered={false} color={s?.color} style={{ marginInlineEnd: 0 }}>
      {s?.text ?? status}
    </Tag>
  );
}

export function PromotionStatusTag({ status }: { status: PromotionStatus }) {
  const s = PROMOTION_STATUS[status];
  return (
    <Tag bordered={false} color={s?.color} style={{ marginInlineEnd: 0 }}>
      {s?.text ?? status}
    </Tag>
  );
}

export function EntryStatusTag({ status, staff }: { status: EntryStatus; staff?: boolean }) {
  const s = ENTRY_STATUS[status];
  return (
    <Tag bordered={false} color={s?.color} style={{ marginInlineEnd: 0 }}>
      {(staff && s?.staff) || s?.text || status}
    </Tag>
  );
}

/** ¥69 <s>¥90</s> */
export function PriceText({ price, original, block }: { price: number; original?: number | null; block?: boolean }) {
  return (
    <span className="num" style={block ? { display: 'block' } : undefined}>
      <b>{yuan(price)}</b>
      {original ? (
        <s className="muted" style={{ marginLeft: 6, fontSize: 12 }}>
          {yuan(original)}
        </s>
      ) : null}
    </span>
  );
}
