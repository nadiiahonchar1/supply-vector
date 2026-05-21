type Props = {
  label: string;
  value: string | number;
};

export function KpiCard({ label, value }: Props) {
  return (
    <div className="rounded-2xl border p-4 shadow-sm">
      <div className="text-sm text-gray-500">{label}</div>
      <div className="text-2xl font-bold">{value}</div>
    </div>
  );
}
