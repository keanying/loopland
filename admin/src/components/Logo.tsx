/** 圈圈 brand mark. [bg] is the colour behind it (the ring's outline matches it); [ring] is the ring colour. */
export default function Logo({ size = 48, dark = true, bg, ring }: { size?: number; dark?: boolean; bg?: string; ring?: string }) {
  const back = bg ?? (dark ? '#141414' : '#FFFFFF');
  const fore = ring ?? (dark ? '#FFFFFF' : '#141414');
  return (
    <svg width={size} height={size} viewBox="14 14 72 72" aria-hidden="true">
      <circle cx="62" cy="50" r="21" fill="#DCF26A" />
      <circle cx="38" cy="50" r="19" fill="none" stroke={back} strokeWidth="15" />
      <circle cx="38" cy="50" r="19" fill="none" stroke={fore} strokeWidth="8" />
      <circle cx="38" cy="31" r="5" fill="#B4A3F5" stroke={back} strokeWidth="2.5" />
    </svg>
  );
}
