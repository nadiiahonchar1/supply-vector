import { NextRequest, NextResponse } from "next/server";

import { createLogisticsRouteSchema } from "@/features/logistics-routes/validation/logistics-route.schema";
import { AuditService } from "@/lib/audit/audit.service";
import { requireUser } from "@/lib/auth/auth-service";
import { handleApiError } from "@/lib/errors/handle-api-error";
import { LogisticsRoutesService } from "@/lib/logistics-routes/logistics-routes.service";
import { validate } from "@/lib/validation";

export async function GET() {
  try {
    const currentUser = await requireUser();

    const routes = await LogisticsRoutesService.getLogisticsRoutes(currentUser);

    return NextResponse.json(routes);
  } catch (error) {
    return handleApiError(error);
  }
}

export async function POST(request: NextRequest) {
  try {
    const currentUser = await requireUser();

    const body = await request.json();

    const input = validate(createLogisticsRouteSchema, body);

    const route = await LogisticsRoutesService.createLogisticsRoute(
      input,
      currentUser,
    );

    await AuditService.log({
      userId: currentUser.id,
      action: "trip:update",
      entity: "logistics_route",
      entityId: route.id,
    });

    return NextResponse.json(route, { status: 201 });
  } catch (error) {
    return handleApiError(error);
  }
}
