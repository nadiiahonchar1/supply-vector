import { getInventory } from "@/features/inventory/api/get-inventory";

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);

  const city = searchParams.get("city") || undefined;

  const lowStock = searchParams.get("lowStock") === "true";

  const data = await getInventory({
    city,
    lowStock,
  });

  return Response.json(data);
}
