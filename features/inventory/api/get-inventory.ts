import { getInventoryQuery } from "../queries/get-inventory-query";

export async function getInventory() {
  return getInventoryQuery();
}
