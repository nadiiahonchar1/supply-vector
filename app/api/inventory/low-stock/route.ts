import { getLowStockQuery } from "@/features/inventory/queries/get-low-stock-query";

export async function GET() {
  const data = await getLowStockQuery();

  return Response.json(data);
}
