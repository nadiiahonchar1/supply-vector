import { NextRequest, NextResponse } from "next/server";

import { requireUser } from "@/lib/auth/server";
import { handleApiError } from "@/lib/errors";
import { LogisticsDecisionsService } from "@/lib/logistics";

type RouteContext = {
  params: Promise<{
    id: string;
  }>;
};

export async function GET(
  _request: NextRequest,
  { params }: RouteContext,
) {
  try {
    const currentUser = await requireUser();

    const { id } = await params;

    const decision =
      await LogisticsDecisionsService.getLogisticsDecisionById(
        id,
        currentUser,
      );

    return NextResponse.json(decision);
  } catch (error) {
    return handleApiError(error);
  }
}

