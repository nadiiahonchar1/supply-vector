import { NextResponse } from "next/server";

import { requireUser } from "@/lib/auth/server";
import { handleApiError } from "@/lib/errors";
import { LogisticsDecisionEngineService } from "@/lib/logistics";

type Params = {
  params: Promise<{
    transferRequestId: string;
  }>;
};

export async function GET(_request: Request, { params }: Params) {
  try {
    const currentUser = await requireUser();

    const { transferRequestId } = await params;

    const recommendations =
      await LogisticsDecisionEngineService.generateRecommendations(
        transferRequestId,
        currentUser,
      );

    return NextResponse.json(recommendations);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function POST(_request: Request, { params }: Params) {
  try {
    const currentUser = await requireUser();

    const { transferRequestId } = await params;

    const result = await LogisticsDecisionEngineService.generateRecommendations(
      transferRequestId,
      currentUser,
    );

    const decisions =
      await LogisticsDecisionEngineService.createSystemLogisticsDecisions(
        transferRequestId,
        result.recommendations,
        currentUser,
      );

    return NextResponse.json(
      {
        transfer_request_id: transferRequestId,
        decisions,
      },
      { status: 201 },
    );
  } catch (error) {
    return handleApiError(error);
  }
}