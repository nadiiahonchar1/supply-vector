import { getKpis } from "@/features/analytics/api/get-kpis";

export async function GET() {
  const data = await getKpis();

  return Response.json(data);
}
