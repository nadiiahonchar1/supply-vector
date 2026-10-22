import { NextResponse } from "next/server";

import { ShipmentsService } from "@/lib/shipments";
import { requireUser } from "@/lib/auth/server";
import { handleApiError } from "@/lib/errors";

type Params = {
  params: Promise<{ id: string }>;
};

export async function GET(_request: Request, { params }: Params) {
  try {
    const currentUser = await requireUser();
    const { id } = await params;

    const items = await ShipmentsService.getShipmentItems(id, currentUser);

    return NextResponse.json(items);
  } catch (error) {
    return handleApiError(error);
  }
}
