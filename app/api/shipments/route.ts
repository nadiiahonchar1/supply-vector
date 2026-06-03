import { NextResponse } from "next/server";

import { getShipmentsQuery } from "@/features/shipments/queries/get-shipments-query";

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);

  const status = searchParams.get("status") ?? undefined;

  const sourceStoreId = searchParams.get("sourceStoreId") ?? undefined;

  const destinationStoreId =
    searchParams.get("destinationStoreId") ?? undefined;

  const shipments = await getShipmentsQuery({
    status: status as
      | "pending"
      | "in_transit"
      | "completed"
      | "cancelled"
      | undefined,

    sourceStoreId,
    destinationStoreId,
  });

  return NextResponse.json(shipments);
}
