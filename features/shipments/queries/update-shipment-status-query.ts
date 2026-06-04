import { sql } from "@/db";
import { ShipmentStatus } from "../types";

type Params = {
  shipmentId: string;
  status: ShipmentStatus;
};

export async function updateShipmentStatusQuery({
  shipmentId,
  status,
}: Params): Promise<void> {
  await sql`
    UPDATE shipments
    SET
      status = ${status},
      completed_at = CASE
        WHEN ${status} = 'completed'
        THEN NOW()
        ELSE completed_at
      END
    WHERE id = ${shipmentId}
  `;
}
