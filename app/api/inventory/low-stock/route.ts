import { getLowStock } from "@/features/inventory/api/get-low-stock";

export async function GET() {
  const data = await getLowStock();

  return Response.json(data);
}
