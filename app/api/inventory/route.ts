import { getInventory } from "@/features/inventory/api/get-inventory";

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);

  const city = searchParams.get("city") || undefined;

  const lowStock = searchParams.get("lowStock") === "true";

  const search = searchParams.get("search") || undefined;

  const page = Number(searchParams.get("page") || 1);

  const limit = Number(searchParams.get("limit") || 20);

  const data = await getInventory({
    city,
    lowStock,
    search,
    page,
    limit,
  });

  return Response.json(data);
}
