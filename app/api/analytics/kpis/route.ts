import { getKpisQuery } from "@/features/analytics/queries/get-kpis-query";

export async function GET() {
  const data = await getKpisQuery();

  return Response.json(data);
}
