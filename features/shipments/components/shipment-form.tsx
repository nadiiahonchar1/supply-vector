"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

import type { StoreOption } from "@/features/stores/types";
import { createShipmentAction } from "../actions/create-shipment";

type Props = {
  stores: StoreOption[];
  products: {
    id: string;
    name: string;
    sku: string;
  }[];
};

type Item = {
  productId: string;
  quantity: number;
};

export function CreateShipmentForm({ stores, products }: Props) {
  const router = useRouter();

  const [sourceStoreId, setSourceStoreId] = useState("");
  const [destinationStoreId, setDestinationStoreId] = useState("");

  const [items, setItems] = useState<Item[]>([{ productId: "", quantity: 1 }]);

  const [loading, setLoading] = useState(false);

  function updateItem(index: number, field: keyof Item, value: string) {
    setItems((prev) =>
      prev.map((item, i) =>
        i === index
          ? {
              ...item,
              [field]: field === "quantity" ? Number(value) : value,
            }
          : item,
      ),
    );
  }

  function addItem() {
    setItems((prev) => [...prev, { productId: "", quantity: 1 }]);
  }

  function removeItem(index: number) {
    setItems((prev) => prev.filter((_, i) => i !== index));
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();

    if (!sourceStoreId || !destinationStoreId) return;

    if (sourceStoreId === destinationStoreId) {
      alert("Source and destination must be different");
      return;
    }

    const validItems = items.filter(
      (item) => item.productId && item.quantity > 0,
    );

    if (!validItems.length) {
      alert("Please select at least one product");
      return;
    }

    const productIds = validItems.map((item) => item.productId);

    if (new Set(productIds).size !== productIds.length) {
      alert("Duplicate products are not allowed");
      return;
    }

    setLoading(true);

    try {
      await createShipmentAction({
        sourceStoreId,
        destinationStoreId,
        items: validItems,
      });

      router.push("/shipments");
      router.refresh();
    } finally {
      setLoading(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} style={{ display: "grid", gap: 12 }}>
      <label>
        Source store
        <select
          value={sourceStoreId}
          onChange={(e) => setSourceStoreId(e.target.value)}
        >
          <option value="">Select store</option>
          {stores.map((s) => (
            <option key={s.id} value={s.id}>
              {s.name} ({s.city})
            </option>
          ))}
        </select>
      </label>

      <label>
        Destination store
        <select
          value={destinationStoreId}
          onChange={(e) => setDestinationStoreId(e.target.value)}
        >
          <option value="">Select store</option>
          {stores.map((s) => (
            <option key={s.id} value={s.id}>
              {s.name} ({s.city})
            </option>
          ))}
        </select>
      </label>

      <div>
        <h3>Items</h3>

        {items.map((item, index) => (
          <div key={index} style={{ display: "flex", gap: 8, marginBottom: 8 }}>
            <select
              value={item.productId}
              onChange={(e) => updateItem(index, "productId", e.target.value)}
            >
              <option value="">Select product</option>

              {products
                .filter(
                  (product) =>
                    product.id === item.productId ||
                    !items.some(
                      (selectedItem) => selectedItem.productId === product.id,
                    ),
                )
                .map((p) => (
                  <option key={p.id} value={p.id}>
                    {p.name} ({p.sku})
                  </option>
                ))}
            </select>

            <input
              type="number"
              min={1}
              value={item.quantity}
              onChange={(e) => updateItem(index, "quantity", e.target.value)}
            />

            <button type="button" onClick={() => removeItem(index)}>
              Remove
            </button>
          </div>
        ))}

        <button type="button" onClick={addItem}>
          + Add item
        </button>
      </div>

      <button type="submit" disabled={loading}>
        {loading ? "Creating..." : "Create shipment"}
      </button>
    </form>
  );
}
