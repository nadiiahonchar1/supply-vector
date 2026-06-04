"use client";

import { useRouter, useSearchParams } from "next/navigation";
import type { StoreOption } from "@/features/stores/types";

type Props = {
  stores: StoreOption[];
};

export function ShipmentsFilters({ stores }: Props) {
  const router = useRouter();
  const searchParams = useSearchParams();

  const currentStatus = searchParams.get("status") ?? "";
  const currentStore = searchParams.get("sourceStoreId") ?? "";
  const currentDestination = searchParams.get("destinationStoreId") ?? "";

  function updateParams(key: string, value: string) {
    const params = new URLSearchParams(searchParams.toString());

    if (value) {
      params.set(key, value);
    } else {
      params.delete(key);
    }

    router.push(`/shipments?${params.toString()}`);
  }

  function resetFilters() {
    router.push("/shipments");
  }

  return (
    <div style={{ marginBottom: 16, display: "flex", gap: 12 }}>
      {/* STATUS */}
      <select
        value={currentStatus}
        onChange={(e) => updateParams("status", e.target.value)}
      >
        <option value="">All statuses</option>
        <option value="pending">Pending</option>
        <option value="in_transit">In transit</option>
        <option value="completed">Completed</option>
        <option value="cancelled">Cancelled</option>
      </select>

      <select
        value={currentStore}
        onChange={(e) => updateParams("sourceStoreId", e.target.value)}
      >
        <option value="">All stores</option>

        {stores.map((store) => (
          <option key={store.id} value={store.id}>
            {store.name} ({store.city})
          </option>
        ))}
      </select>

      <select
        value={currentDestination}
        onChange={(e) => updateParams("destinationStoreId", e.target.value)}
      >
        <option value="">All destinations</option>
        {stores.map((s) => (
          <option key={s.id} value={s.id}>
            {s.name} ({s.city})
          </option>
        ))}
      </select>
      <button onClick={resetFilters}>Reset</button>
    </div>
  );
}
