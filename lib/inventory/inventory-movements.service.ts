import { sql } from "@/db";
import { INVENTORY_TEXT } from "@/features/inventory";
import { hasPermission, PERMISSIONS } from "@/lib/auth";
import { ForbiddenError } from "@/lib/errors";

import type { InventoryMovement, InventoryMovementFilters } from "@/features/inventory";
import type { CurrentUser } from "@/features/auth";

export class InventoryMovementsService {
  static async getMovements(
    currentUser: CurrentUser,
    filters: InventoryMovementFilters = {},
  ): Promise<InventoryMovement[]> {
    if (!hasPermission(currentUser.role, PERMISSIONS.INVENTORY_VIEW)) {
      throw new ForbiddenError(INVENTORY_TEXT.error.forbidden_view);
    }

    const result = await sql`
      SELECT
        im.id,
        im.store_id,
        s.name AS store_name,
        im.product_id,
        p.name AS product_name,
        p.sku,

        im.quantity_change,
        im.quantity_before,
        im.quantity_after,

        im.movement_type,
        im.shipment_id,
        im.shipment_item_id,
        im.created_by,
        im.created_at
      FROM inventory_movements im
      JOIN stores s
        ON s.id = im.store_id
      JOIN products p
        ON p.id = im.product_id
      WHERE
        (
          ${filters.store_id ?? null}::uuid IS NULL
          OR im.store_id = ${filters.store_id ?? null}::uuid
        )
        AND (
          ${filters.product_id ?? null}::uuid IS NULL
          OR im.product_id = ${filters.product_id ?? null}::uuid
        )
        AND (
          ${filters.movement_type ?? null}::text IS NULL
          OR im.movement_type = ${filters.movement_type ?? null}::text
        )
      ORDER BY im.created_at DESC, im.id DESC
    `;

    return result as InventoryMovement[];
  }
}
