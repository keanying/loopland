export default function Logo({ size = 48, dark = true }: { size?: number; dark?: boolean }) {
  const bg = dark ? '#141414' : '#FFFFFF';
  return (
    <svg width={size} height={size} viewBox="14 14 72 72" aria-hidden="true">
      <circle cx="62" cy="50" r="21" fill="#DCF26A" />
      <circle cx="38" cy="50" r="19" fill="none" stroke={bg} strokeWidth="15" />
      <circle cx="38" cy="50" r="19" fill="none" stroke={dark ? '#FFFFFF' : '#141414'} strokeWidth="8" />
      <circle cx="38" cy="31" r="5" fill="#B4A3F5" stroke={bg} strokeWidth="2.5" />
    </svg>
  );
}
