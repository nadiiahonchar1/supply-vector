import { InventoryFilters } from "../types";

import { getInventoryQuery } from "../queries/get-inventory-query";

export async function getInventory(filters?: InventoryFilters) {
  return getInventoryQuery(filters);
}
