"use client";

import { useRouter, useSearchParams } from "next/navigation";

export function ShipmentsFilters() {
  const router = useRouter();
  const searchParams = useSearchParams();

  const currentStatus = searchParams.get("status") ?? "";

  function setStatus(status: string) {
    const params = new URLSearchParams(searchParams.toString());

    if (status) {
      params.set("status", status);
    } else {
      params.delete("status");
    }

    router.push(`/shipments?${params.toString()}`);
  }

  return (
    <div style={{ marginBottom: 16 }}>
      <select value={currentStatus} onChange={(e) => setStatus(e.target.value)}>
        <option value="">All statuses</option>
        <option value="pending">Pending</option>
        <option value="in_transit">In transit</option>
        <option value="completed">Completed</option>
        <option value="cancelled">Cancelled</option>
      </select>
    </div>
  );
}
