import { getLowStockQuery } from "../queries/get-low-stock-query";

export async function getLowStock() {
  return getLowStockQuery();
}
