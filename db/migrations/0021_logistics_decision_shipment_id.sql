ALTER TABLE logistics_decisions
ADD COLUMN shipment_id UUID
REFERENCES shipments(id)
ON DELETE SET NULL;

CREATE INDEX idx_logistics_decisions_shipment_id
ON logistics_decisions(shipment_id);