import { NextRequest, NextResponse } from "next/server";

import { updateLogisticsRouteSchema } from "@/features/logistics-routes/validation/logistics-route.schema";
import { AuditService } from "@/lib/audit/audit.service";
import { requireUser } from "@/lib/auth/auth-service";
import { handleApiError } from "@/lib/errors/handle-api-error";
import { LogisticsRoutesService } from "@/lib/logistics-routes/logistics-routes.service";
import { validate } from "@/lib/validation";

type RouteContext = {
  params: Promise<{
    id: string;
  }>;
};

export async function GET(_request: NextRequest, { params }: RouteContext) {
  try {
    const currentUser = await requireUser();

    const { id } = await params;

    const route = await LogisticsRoutesService.getLogisticsRouteById(
      id,
      currentUser,
    );

    return NextResponse.json(route);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function PATCH(request: NextRequest, { params }: RouteContext) {
  try {
    const currentUser = await requireUser();

    const { id } = await params;

    const body = await request.json();

    const input = validate(updateLogisticsRouteSchema, body);

    const route = await LogisticsRoutesService.updateLogisticsRoute(
      id,
      input,
      currentUser,
    );

    await AuditService.log({
      userId: currentUser.id,
      action: "trip:update",
      entity: "logistics_route",
      entityId: route.id,
    });

    return NextResponse.json(route);
  } catch (error) {
    return handleApiError(error);
  }
}
