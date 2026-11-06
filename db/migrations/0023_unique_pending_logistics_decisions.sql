WITH ranked_decisions AS (
  SELECT
    id,
    ROW_NUMBER() OVER (
      PARTITION BY transfer_request_id, shipment_id
      ORDER BY created_at DESC, id DESC
    ) AS row_number
  FROM logistics_decisions
  WHERE decision_source = 'system'
    AND decision_status = 'pending'
    AND shipment_id IS NOT NULL
)
UPDATE logistics_decisions AS decisions
SET decision_status = 'superseded'
FROM ranked_decisions
WHERE decisions.id = ranked_decisions.id
  AND ranked_decisions.row_number > 1;

DROP INDEX IF EXISTS idx_logistics_decisions_current;

CREATE UNIQUE INDEX idx_logistics_decisions_current
ON logistics_decisions (
  transfer_request_id,
  shipment_id
)
WHERE decision_source = 'system'
  AND decision_status = 'pending';