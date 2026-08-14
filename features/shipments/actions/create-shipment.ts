"use server";

type Item = {
  productId: string;
  quantity: number;
};

type Params = {
  sourceStoreId: string;
  destinationStoreId: string;
  items: Item[];
};

// TODO: not implemented yet — this is a stub so the app compiles
// and deploys while shipment creation is still being built. Wire
// up the real INSERT INTO shipments / shipment_items logic here
// (see updateShipmentStatusAction in this same folder for the
// stock-check + sql query conventions used elsewhere in this feature).
export async function createShipmentAction(_params: Params): Promise<void> {
    console.log(_params);
  throw new Error("Shipment creation is not implemented yet");
}
