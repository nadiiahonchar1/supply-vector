import { notFound } from "next/navigation";
import { getShipmentByIDQuery } from "@/features/shipments/queries/get-shipment-by-id-query";
import { ShipmentDetailsPage } from "@/features/shipments/components/shipment-details-page";

type Props = {
  params: Promise<{
    id: string;
  }>;
};

export default async function Page({ params }: Props) {
  const { id } = await params;

  const shipment = await getShipmentByIDQuery(id);

  if (!shipment) {
    notFound();
  }

  return <ShipmentDetailsPage shipment={shipment} />;
}
