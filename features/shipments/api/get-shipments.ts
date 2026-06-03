export async function getShipments() {
  const response = await fetch("/api/shipments");

  if (!response.ok) {
    throw new Error("Failed to fetch shipments");
  }

  return response.json();
}
