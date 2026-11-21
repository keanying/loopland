// Inline SVG "photos" for mock mode, so the review and post pages have images
// to preview without any network request.

const SKIES = [
  ['#FFB88C', '#DE6262'],
  ['#89F7FE', '#66A6FF'],
  ['#2B5876', '#4E4376'],
  ['#F6D365', '#FDA085'],
  ['#A1C4FD', '#C2E9FB'],
  ['#0F2027', '#2C5364'],
  ['#D4FC79', '#96E6A1'],
  ['#FBC2EB', '#A6C1EE'],
];

const svgUri = (svg: string) => `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;

/** A landscape-ish picture: gradient sky, sun or moon, skyline, a running path and a caption. */
export function photo(seed: number, caption: string, w = 1080, h = 1440): string {
  const [a, b] = SKIES[seed % SKIES.length];
  const night = seed % SKIES.length === 2 || seed % SKIES.length === 5;
  const sx = 200 + ((seed * 137) % 680);
  const ground = h * 0.66;
  const buildings = Array.from({ length: 9 }, (_, i) => {
    const bw = w / 9;
    const bh = 120 + ((seed * 31 + i * 97) % 380);
    return `<rect x="${(i * bw).toFixed(0)}" y="${(ground - bh).toFixed(0)}" width="${(bw - 8).toFixed(0)}" height="${bh}" fill="${night ? '#1b1b2e' : '#3b3b4f'}" opacity="${0.55 + (i % 3) * 0.15}"/>`;
  }).join('');
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">
<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${a}"/><stop offset="1" stop-color="${b}"/></linearGradient></defs>
<rect width="${w}" height="${h}" fill="url(#g)"/>
<circle cx="${sx}" cy="${h * 0.2}" r="${night ? 60 : 110}" fill="${night ? '#F4F1C9' : '#FFF4D6'}" opacity="0.9"/>
${buildings}
<rect y="${ground}" width="${w}" height="${h - ground}" fill="${night ? '#22313f' : '#5c8a4b'}"/>
<path d="M ${w * 0.1} ${h} C ${w * 0.35} ${h * 0.84}, ${w * 0.7} ${h * 0.86}, ${w * 0.55} ${ground}" stroke="#DCF26A" stroke-width="26" fill="none" stroke-linecap="round" stroke-dasharray="60 34"/>
<rect x="40" y="${h - 150}" rx="24" width="${Math.min(w - 80, 60 + caption.length * 46)}" height="96" fill="rgba(0,0,0,.45)"/>
<text x="70" y="${h - 86}" font-size="44" font-family="sans-serif" font-weight="700" fill="#fff">${caption}</text>
</svg>`;
  return svgUri(svg);
}

/** A square avatar: coloured circle with one character. */
export function avatar(seed: number, ch: string): string {
  const [a, b] = SKIES[(seed + 3) % SKIES.length];
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">
<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${a}"/><stop offset="1" stop-color="${b}"/></linearGradient></defs>
<rect width="512" height="512" fill="url(#g)"/>
<circle cx="256" cy="200" r="96" fill="rgba(255,255,255,.85)"/>
<path d="M 96 470 C 120 330, 392 330, 416 470 Z" fill="rgba(255,255,255,.85)"/>
<text x="256" y="236" font-size="110" text-anchor="middle" font-family="sans-serif" font-weight="800" fill="#141414">${ch}</text>
</svg>`;
  return svgUri(svg);
}

/** A promo-style picture (QR code block + slogan), the kind reviewers should reject. */
export function promo(seed: number, slogan: string): string {
  const cells = Array.from({ length: 81 }, (_, i) => ((i * 7 + seed * 13) % 5 < 2 ? `<rect x="${330 + (i % 9) * 46}" y="${520 + Math.floor(i / 9) * 46}" width="46" height="46" fill="#141414"/>` : '')).join('');
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1080" height="1440" viewBox="0 0 1080 1440">
<rect width="1080" height="1440" fill="#FFE14D"/>
<text x="540" y="300" font-size="88" text-anchor="middle" font-family="sans-serif" font-weight="900" fill="#D93A2B">${slogan}</text>
<text x="540" y="410" font-size="44" text-anchor="middle" font-family="sans-serif" fill="#141414">长按识别二维码进群</text>
<rect x="310" y="500" width="460" height="460" fill="#fff"/>
${cells}
<text x="540" y="1120" font-size="40" text-anchor="middle" font-family="sans-serif" fill="#141414">名额有限 · 先到先得</text>
</svg>`;
  return svgUri(svg);
}
