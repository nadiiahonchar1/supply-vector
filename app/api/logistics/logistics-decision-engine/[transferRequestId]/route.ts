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
