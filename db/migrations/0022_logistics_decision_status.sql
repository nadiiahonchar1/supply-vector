ALTER TABLE logistics_decisions
ADD COLUMN decision_status TEXT
CHECK (
  decision_status IN (
    'pending',
    'accepted',
    'rejected',
    'superseded'
  )
);

UPDATE logistics_decisions
SET decision_status = 'pending'
WHERE decision_source = 'system';

CREATE INDEX idx_logistics_decisions_current
ON logistics_decisions (
  transfer_request_id,
  shipment_id
)
WHERE decision_source = 'system'
AND decision_status = 'pending';