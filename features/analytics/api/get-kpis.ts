import { getKpisQuery } from "../queries/get-kpis-query";

export async function getKpis() {
  return getKpisQuery();
}
