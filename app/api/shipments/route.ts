import { NextResponse } from "next/server";

import { getShipmentsQuery } from "@/features/shipments/queries/get-shipments-query";

export async function GET() {
  try {
    const shipments = await getShipmentsQuery();

    return NextResponse.json(shipments);
  } catch (error) {
    console.error(error);

    return NextResponse.json(
      {
        message: "Failed to fetch shipments",
      },
      {
        status: 500,
      },
    );
  }
}
