import { getInventory } from "@/features/inventory/api/get-inventory";

export async function GET() {
  const data = await getInventory();

  return Response.json(data);
}
