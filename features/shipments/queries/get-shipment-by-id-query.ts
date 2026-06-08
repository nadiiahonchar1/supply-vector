import { getShipmentsQuery } from "./get-shipments-query";

export async function getShipmentByIDQuery(id: string) {
  const shipments = await getShipmentsQuery();

  return shipments.find((shipment) => shipment.shipment_id === id);
}
