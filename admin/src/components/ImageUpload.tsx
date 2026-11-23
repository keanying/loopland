// V2 第六批 · 管理端图片上传 (docs/api/v2-6-管理端图片上传与站内信.md「管理端图片上传」).
// Picture-card uploader for form fields that hold image URLs: files go to POST /admin/v1/media with a `purpose`,
// the field keeps plain URLs (string[] for ImageUpload, string for SingleImageUpload), so existing forms and the
// API bodies keep their shape. A pasted https URL still works (external image hosts, older data).
import { useEffect, useRef, useState, type DragEvent } from 'react';
import { App, Button, Image, Input, Progress, Tooltip, Upload } from 'antd';
import type { UploadProps } from 'antd';
import { api } from '../api/admin';
import { ApiError } from '../api/client';
import type { MediaPurpose } from '../api/types';
import { DoodlePicture } from './icons';
import { Glyph } from './Glyph';

const MAX_BYTES = 10 * 1024 * 1024;
const EXT_RE = /\.(jpe?g|png|webp|heic|heif)$/i;
const MIME_RE = /^image\/(jpeg|png|webp|heic|heif)$/i;
const ACCEPT = 'image/jpeg,image/png,image/webp,image/heic,image/heif,.jpg,.jpeg,.png,.webp,.heic,.heif';
/** Pasted URLs: http(s), a server path (/v1/media/files/…), or a data URL from mock mode. */
const URL_RE = /^(https?:\/\/\S+|\/\S+|data:image\/\S+)$/;

/** 3:1 banners, 16:9 covers, square product shots / licences. */
type Shape = 'square' | 'cover' | 'banner';
const TILE: Record<Shape, { w: number; h: number }> = {
  square: { w: 104, h: 104 },
  cover: { w: 176, h: 99 },
  banner: { w: 240, h: 80 },
};

function uploadError(err: unknown): string {
  if (err instanceof ApiError) {
    switch (err.code) {
      case 'unsupported_media':
        return '不支持这个格式：只能上传 jpg / png / webp / heic 图片';
      case 'file_too_large':
        return '图片超过 10 MB，压缩后再上传';
      case 'rate_limited':
        return '今天上传的图片已达上限（每个账号每天 500 张），明天再试，或先粘贴图片网址';
      case 'media_unavailable':
        return '图片存储暂不可用，请稍后再试，或先粘贴图片网址';
      case 'forbidden':
        return '当前账号不能上传这类图片';
      case 'invalid_body':
        return `上传失败：${err.message}`;
      default:
        return err.message || '上传失败，请重试';
    }
  }
  return err instanceof Error ? err.message : '上传失败，请重试';
}

interface Pending {
  uid: string;
  name: string;
  preview: string;
  percent: number;
  error: string | null;
  file: File;
}

export interface ImageUploadProps {
  value?: string[] | null;
  onChange?: (urls: string[]) => void;
  purpose: MediaPurpose;
  /** Maximum number of images (default 9). */
  max?: number;
  shape?: Shape;
  disabled?: boolean;
  /** Extra hint under the tiles (size advice etc.). */
  hint?: string;
  /** Show the「封面」badge on the first image (multi-image fields where the first one is the cover). */
  coverFirst?: boolean;
  /** Accessible name for the field, e.g. "商品图片". */
  label?: string;
}

/** Multi-image field: value is string[] of URLs; drag tiles to reorder. */
export function ImageUpload({ value, onChange, purpose, max = 9, shape = 'square', disabled, hint, coverFirst, label = '图片' }: ImageUploadProps) {
  const { message } = App.useApp();
  const urls = value ?? [];
  // Uploads can finish between renders: build each new value on the latest one, not on a stale prop.
  const latest = useRef<string[]>(urls);
  useEffect(() => {
    latest.current = value ?? [];
  }, [value]);
  const [pending, setPending] = useState<Pending[]>([]);
  const pendingRef = useRef<Pending[]>([]);
  pendingRef.current = pending;
  const [pasting, setPasting] = useState(false);
  const [pasteText, setPasteText] = useState('');
  const [pasteError, setPasteError] = useState<string | null>(null);
  const [dragFrom, setDragFrom] = useState<number | null>(null);
  const [dragOver, setDragOver] = useState<number | null>(null);
  const tile = TILE[shape];
  const slotsLeft = max - urls.length - pending.filter((p) => !p.error).length;

  useEffect(
    () => () => {
      for (const p of pendingRef.current) URL.revokeObjectURL(p.preview);
    },
    [],
  );

  const emit = (next: string[]) => {
    latest.current = next;
    onChange?.(next);
  };

  const patch = (uid: string, change: Partial<Pending>) => setPending((list) => list.map((p) => (p.uid === uid ? { ...p, ...change } : p)));
  const drop = (uid: string) =>
    setPending((list) => {
      const hit = list.find((p) => p.uid === uid);
      if (hit) URL.revokeObjectURL(hit.preview);
      return list.filter((p) => p.uid !== uid);
    });

  const start = (file: File, uid: string) => {
    patch(uid, { error: null, percent: 0 });
    api
      .uploadMedia(file, purpose, { onProgress: (percent) => patch(uid, { percent }) })
      .then((media) => {
        if (latest.current.length >= max) {
          message.warning(`最多 ${max} 张，多出的没有加入`);
        } else {
          emit([...latest.current, media.url]);
        }
        drop(uid);
      })
      .catch((err: unknown) => {
        const text = uploadError(err);
        patch(uid, { error: text, percent: 0 });
        message.error(`「${file.name}」${text}`);
      });
  };

  // Track how many files one multi-select adds, so the max-count warning shows once.
  const warnedBatch = useRef<unknown>(null);

  const beforeUpload: UploadProps['beforeUpload'] = (file, fileList) => {
    if (!(MIME_RE.test(file.type) || EXT_RE.test(file.name))) {
      message.error(`「${file.name}」不是 jpg / png / webp / heic 图片`);
      return Upload.LIST_IGNORE;
    }
    if (file.size > MAX_BYTES) {
      message.error(`「${file.name}」超过 10 MB，压缩后再上传`);
      return Upload.LIST_IGNORE;
    }
    const index = fileList.indexOf(file);
    if (index >= slotsLeft) {
      if (warnedBatch.current !== fileList) {
        warnedBatch.current = fileList;
        message.warning(`最多 ${max} 张，只上传了前 ${Math.max(0, slotsLeft)} 张`);
      }
      return Upload.LIST_IGNORE;
    }
    return true;
  };

  const customRequest: UploadProps['customRequest'] = ({ file }) => {
    const f = file as File & { uid: string };
    const uid = f.uid ?? `${Date.now()}-${Math.random()}`;
    setPending((list) => [...list, { uid, name: f.name, preview: URL.createObjectURL(f), percent: 0, error: null, file: f }]);
    start(f, uid);
  };

  const remove = (i: number) => emit(urls.filter((_, k) => k !== i));

  const move = (from: number, to: number) => {
    if (from === to) return;
    const next = [...urls];
    const [x] = next.splice(from, 1);
    next.splice(to, 0, x);
    emit(next);
  };

  const addPasted = () => {
    const u = pasteText.trim();
    if (!URL_RE.test(u)) {
      setPasteError('需要是 https:// 开头的图片网址');
      return;
    }
    if (urls.includes(u)) {
      setPasteError('这张图片已经在里面了');
      return;
    }
    emit([...urls, u]);
    setPasteText('');
    setPasteError(null);
    if (urls.length + 1 >= max) setPasting(false);
  };

  const dragProps = (i: number) =>
    disabled || urls.length < 2
      ? {}
      : {
          draggable: true,
          onDragStart: (e: DragEvent) => {
            setDragFrom(i);
            e.dataTransfer.effectAllowed = 'move';
            e.dataTransfer.setData('text/plain', String(i));
          },
          onDragOver: (e: DragEvent) => {
            if (dragFrom === null) return;
            e.preventDefault();
            setDragOver(i);
          },
          onDragLeave: () => setDragOver((v) => (v === i ? null : v)),
          onDrop: (e: DragEvent) => {
            e.preventDefault();
            if (dragFrom !== null) move(dragFrom, i);
            setDragFrom(null);
            setDragOver(null);
          },
          onDragEnd: () => {
            setDragFrom(null);
            setDragOver(null);
          },
        };

  return (
    <div className="img-up" role="group" aria-label={label}>
      <div className="img-up-grid">
        <Image.PreviewGroup>
          {urls.map((u, i) => (
            <div
              key={i}
              className={'img-up-tile' + (dragOver === i && dragFrom !== i ? ' over' : '') + (dragFrom === i ? ' dragging' : '')}
              style={{ width: tile.w, height: tile.h }}
              title={urls.length > 1 && !disabled ? '拖动调整顺序' : undefined}
              {...dragProps(i)}
            >
              <Image
                src={u}
                width={tile.w}
                height={tile.h}
                alt={`${label} ${i + 1}`}
                draggable={false}
                preview={{
                  mask: (
                    <span className="img-up-mask">
                      <Glyph name="eye" size={18} /> 预览
                    </span>
                  ),
                }}
              />
              {coverFirst && i === 0 && urls.length > 1 && <span className="img-up-badge">封面</span>}
              {!disabled && (
                <Tooltip title="移除">
                  <button type="button" className="img-up-remove" aria-label={`移除第 ${i + 1} 张`} onClick={() => remove(i)}>
                    <Glyph name="trash" size={14} />
                  </button>
                </Tooltip>
              )}
            </div>
          ))}
        </Image.PreviewGroup>
        {pending.map((p) => (
          <div key={p.uid} className={'img-up-tile pending' + (p.error ? ' failed' : '')} style={{ width: tile.w, height: tile.h }}>
            <img src={p.preview} alt="" />
            <div className="img-up-state">
              {p.error ? (
                <>
                  <Tooltip title={p.error}>
                    <span className="img-up-fail">上传失败</span>
                  </Tooltip>
                  <span className="img-up-actions">
                    <Button size="small" type="link" onClick={() => start(p.file, p.uid)}>
                      重试
                    </Button>
                    <Button size="small" type="link" onClick={() => drop(p.uid)}>
                      移除
                    </Button>
                  </span>
                </>
              ) : (
                <Progress type="circle" size={38} percent={p.percent} showInfo={false} strokeColor="#141414" />
              )}
            </div>
          </div>
        ))}
        {!disabled && slotsLeft > 0 && (
          <Upload
            accept={ACCEPT}
            multiple={max > 1}
            showUploadList={false}
            fileList={[]}
            beforeUpload={beforeUpload}
            customRequest={customRequest}
            className="img-up-trigger-wrap"
          >
            <button type="button" className="img-up-trigger" style={{ width: tile.w, height: tile.h }} aria-label={`上传${label}`}>
              <DoodlePicture width={shape === 'banner' ? 34 : 38} />
              <span>{urls.length ? '继续上传' : '上传图片'}</span>
            </button>
          </Upload>
        )}
      </div>
      <div className="img-up-foot">
        <span className="muted">
          jpg / png / webp / heic，单张 ≤ 10 MB{max > 1 ? `，最多 ${max} 张` : ''}
          {urls.length > 1 && !disabled ? '；拖动可调整顺序' : ''}
          {hint ? `；${hint}` : ''}
        </span>
        {!disabled && slotsLeft > 0 && !pasting && (
          <button type="button" className="img-up-paste-link" onClick={() => setPasting(true)}>
            <Glyph name="link" size={14} /> 或粘贴图片网址
          </button>
        )}
      </div>
      {pasting && !disabled && (
        <div className="img-up-paste">
          <Input
            size="small"
            autoFocus
            allowClear
            value={pasteText}
            status={pasteError ? 'error' : undefined}
            placeholder="https://… 图片网址"
            onChange={(e) => {
              setPasteText(e.target.value);
              setPasteError(null);
            }}
            onPressEnter={(e) => {
              e.preventDefault();
              addPasted();
            }}
          />
          <Button size="small" type="primary" onClick={addPasted} disabled={!pasteText.trim()}>
            添加
          </Button>
          <Button
            size="small"
            onClick={() => {
              setPasting(false);
              setPasteText('');
              setPasteError(null);
            }}
          >
            取消
          </Button>
          {pasteError && <div className="img-up-paste-error">{pasteError}</div>}
        </div>
      )}
    </div>
  );
}

/** Single-image field (cover, banner): value is a URL string ('' when empty). */
export function SingleImageUpload({ value, onChange, ...rest }: Omit<ImageUploadProps, 'value' | 'onChange' | 'max' | 'coverFirst'> & { value?: string | null; onChange?: (url: string) => void }) {
  const v = value?.trim();
  return <ImageUpload {...rest} max={1} value={v ? [v] : []} onChange={(urls) => onChange?.(urls[0] ?? '')} />;
}
