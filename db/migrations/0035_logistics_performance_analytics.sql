-- =========================================================
-- 1. DELIVERY TIME
-- =========================================================

CREATE OR REPLACE VIEW v_shipment_delivery_performance AS
SELECT
  s.id AS shipment_id,
  s.shipment_number,
  s.transfer_request_id,
  s.trip_id,
  s.source_storage_point_id,
  s.destination_storage_point_id,
  s.status,

  s.created_at,

  departure.actual_departure_at,

  receiving.first_received_at,
  receiving.last_received_at,

  CASE
    WHEN departure.actual_departure_at IS NOT NULL
     AND receiving.last_received_at IS NOT NULL
    THEN EXTRACT(
      EPOCH FROM (
        receiving.last_received_at
        - departure.actual_departure_at
      )
    ) / 3600
    ELSE NULL
  END AS delivery_duration_hours,

  receiving.received_quantity,

  COALESCE(cargo.returned_quantity, 0)
    AS returned_quantity,

  COALESCE(cargo.lost_quantity, 0)
    AS lost_quantity,

  COALESCE(cargo.writeoff_quantity, 0)
    AS written_off_quantity,

  COALESCE(cargo.transferred_quantity, 0)
    AS responsibility_transferred_quantity

FROM shipments s

LEFT JOIN trips departure_trip
  ON departure_trip.id = s.trip_id

LEFT JOIN LATERAL (
  SELECT
    departure_trip.actual_departure_at
) departure ON TRUE

LEFT JOIN (
  SELECT
    si.shipment_id,

    MIN(rm.received_at) AS first_received_at,

    MAX(rm.received_at) AS last_received_at,

    SUM(rm.quantity) AS received_quantity

  FROM shipment_receipt_movements rm

  JOIN shipment_items si
    ON si.id = rm.shipment_item_id

  GROUP BY si.shipment_id
) receiving
  ON receiving.shipment_id = s.id

LEFT JOIN (
  SELECT
    si.shipment_id,

    SUM(m.quantity) FILTER (
      WHERE m.movement_type = 'return'
    ) AS returned_quantity,

    SUM(m.quantity) FILTER (
      WHERE m.movement_type = 'loss'
    ) AS lost_quantity,

    SUM(m.quantity) FILTER (
      WHERE m.movement_type = 'writeoff'
    ) AS writeoff_quantity,

    SUM(m.quantity) FILTER (
      WHERE m.movement_type = 'responsibility_transfer'
    ) AS transferred_quantity

  FROM shipment_cargo_movements m

  JOIN shipment_items si
    ON si.id = m.shipment_item_id

  GROUP BY si.shipment_id
) cargo
  ON cargo.shipment_id = s.id;


-- =========================================================
-- 2. ADHERENCE TO SCHEDULED ARRIVAL TIME
-- =========================================================

CREATE OR REPLACE VIEW v_trip_stop_performance AS
SELECT
  ts.id AS trip_stop_id,
  ts.trip_id,
  t.trip_number,

  ts.storage_point_id,
  sp.name AS storage_point_name,

  ts.sequence,

  ts.planned_arrival_at,
  ts.actual_arrival_at,

  CASE
    WHEN ts.planned_arrival_at IS NOT NULL
     AND ts.actual_arrival_at IS NOT NULL
    THEN ROUND(
      (
        EXTRACT(
          EPOCH FROM (
            ts.actual_arrival_at
            - ts.planned_arrival_at
          )
        ) / 60
      )::NUMERIC,
      2
    )
    ELSE NULL
  END AS arrival_delay_minutes,

  CASE
    WHEN ts.planned_arrival_at IS NULL
      OR ts.actual_arrival_at IS NULL
    THEN 'not_measurable'

    WHEN ts.actual_arrival_at <= ts.planned_arrival_at
    THEN 'on_time'

    ELSE 'delayed'
  END AS arrival_performance

FROM trip_stops ts

JOIN trips t
  ON t.id = ts.trip_id

JOIN storage_points sp
  ON sp.id = ts.storage_point_id;


-- =========================================================
-- 3. PARTIAL DELIVERIES
-- =========================================================

CREATE OR REPLACE VIEW v_partial_delivery_analytics AS
SELECT
  s.id AS shipment_id,
  s.shipment_number,
  s.trip_id,
  s.transfer_request_id,
  s.status,

  COUNT(si.id) AS item_count,

  COALESCE(
    SUM(si.planned_quantity),
    0
  ) AS planned_quantity,

  COALESCE(
    SUM(received.received_quantity),
    0
  ) AS received_quantity,

  COALESCE(
    SUM(cargo.returned_quantity),
    0
  ) AS returned_quantity,

  COALESCE(
    SUM(cargo.lost_quantity),
    0
  ) AS lost_quantity,

  COALESCE(
    SUM(cargo.writeoff_quantity),
    0
  ) AS written_off_quantity,

  COALESCE(
    SUM(cargo.transferred_quantity),
    0
  ) AS responsibility_transferred_quantity

FROM shipments s

JOIN shipment_items si
  ON si.shipment_id = s.id

LEFT JOIN LATERAL (
  SELECT
    COALESCE(SUM(rm.quantity), 0) AS received_quantity
  FROM shipment_receipt_movements rm
  WHERE rm.shipment_item_id = si.id
) received ON TRUE

LEFT JOIN LATERAL (
  SELECT
    COALESCE(
      SUM(m.quantity) FILTER (
        WHERE m.movement_type = 'return'
      ),
      0
    ) AS returned_quantity,

    COALESCE(
      SUM(m.quantity) FILTER (
        WHERE m.movement_type = 'loss'
      ),
      0
    ) AS lost_quantity,

    COALESCE(
      SUM(m.quantity) FILTER (
        WHERE m.movement_type = 'writeoff'
      ),
      0
    ) AS written_off_quantity,

    COALESCE(
      SUM(m.quantity) FILTER (
        WHERE m.movement_type = 'responsibility_transfer'
      ),
      0
    ) AS transferred_quantity

  FROM shipment_cargo_movements m
  WHERE m.shipment_item_id = si.id
) cargo ON TRUE

GROUP BY
  s.id,
  s.shipment_number,
  s.trip_id,
  s.transfer_request_id,
  s.status

HAVING
  COALESCE(SUM(received.received_quantity), 0) > 0
  AND COALESCE(SUM(si.planned_quantity), 0)
      > COALESCE(SUM(received.received_quantity), 0);


-- =========================================================
-- 4. DISCREPANCIES DURING THE ADJUSTMENT OF BALANCE
-- =========================================================

CREATE OR REPLACE VIEW v_inventory_adjustment_analytics AS
SELECT
  im.id AS movement_id,

  im.storage_point_id,
  sp.name AS storage_point_name,

  im.product_id,
  p.sku,
  p.name AS product_name,

  im.quantity_before,
  im.quantity_after,

  (
    im.quantity_after - im.quantity_before
  ) AS quantity_difference,

  im.reason,
  im.reference_type,
  im.reference_id,

  im.created_by,
  im.created_at

FROM inventory_movements im

JOIN storage_points sp
  ON sp.id = im.storage_point_id

JOIN products p
  ON p.id = im.product_id

WHERE im.movement_type = 'adjustment';


-- =========================================================
-- 5. EFFICIENCY OF TRANSPORT USE
-- =========================================================

CREATE OR REPLACE VIEW v_vehicle_utilization_analytics AS
SELECT
  v.id AS vehicle_id,
  v.registration_number,
  v.brand,
  v.model,

  v.max_weight_kg,
  v.max_volume_m3,

  COUNT(t.id) AS total_trips,

  COUNT(t.id) FILTER (
    WHERE t.status = 'delivered'
  ) AS completed_trips,

  COUNT(t.id) FILTER (
    WHERE t.status = 'cancelled'
  ) AS cancelled_trips,

  COALESCE(
    AVG(util.weight_utilization_percent),
    0
  ) AS average_weight_utilization_percent,

  COALESCE(
    AVG(util.volume_utilization_percent),
    0
  ) AS average_volume_utilization_percent

FROM vehicles v

LEFT JOIN trips t
  ON t.vehicle_id = v.id

LEFT JOIN v_trip_cargo_utilization util
  ON util.trip_id = t.id

GROUP BY
  v.id,
  v.registration_number,
  v.brand,
  v.model,
  v.max_weight_kg,
  v.max_volume_m3;


-- =========================================================
-- 6. GENERAL DELIVERY METRICS
-- =========================================================

CREATE OR REPLACE VIEW v_delivery_performance_summary AS
SELECT
  COUNT(*) AS total_shipments,

  COUNT(*) FILTER (
    WHERE status = 'delivered'
  ) AS fully_delivered_shipments,

  COUNT(*) FILTER (
    WHERE status = 'partially_fulfilled'
  ) AS partially_fulfilled_shipments,

  COUNT(*) FILTER (
    WHERE status = 'partially_delivered'
  ) AS partially_delivered_shipments,

  COUNT(*) FILTER (
    WHERE status = 'returned'
  ) AS returned_shipments,

  COUNT(*) FILTER (
    WHERE status = 'lost'
  ) AS lost_shipments,

  COUNT(*) FILTER (
    WHERE status = 'settled'
  ) AS settled_shipments,

  ROUND(
    AVG(delivery_duration_hours)::NUMERIC,
    2
  ) AS average_delivery_duration_hours,

  ROUND(
    MAX(delivery_duration_hours)::NUMERIC,
    2
  ) AS maximum_delivery_duration_hours

FROM v_shipment_delivery_performance;


-- =========================================================
-- 7. GENERAL STATISTICS OF ARRIVALS AT POINTS
-- =========================================================

CREATE OR REPLACE VIEW v_arrival_performance_summary AS
SELECT
  COUNT(*) FILTER (
    WHERE arrival_performance IN ('on_time', 'delayed')
  ) AS measurable_arrivals,

  COUNT(*) FILTER (
    WHERE arrival_performance = 'on_time'
  ) AS on_time_arrivals,

  COUNT(*) FILTER (
    WHERE arrival_performance = 'delayed'
  ) AS delayed_arrivals,

  ROUND(
    (
      COUNT(*) FILTER (
        WHERE arrival_performance = 'on_time'
      )::NUMERIC
      /
      NULLIF(
        COUNT(*) FILTER (
          WHERE arrival_performance IN ('on_time', 'delayed')
        ),
        0
      )
    ) * 100,
    2
  ) AS on_time_arrival_percent,

  ROUND(
    AVG(arrival_delay_minutes) FILTER (
      WHERE arrival_performance = 'delayed'
    ),
    2
  ) AS average_delay_minutes

FROM v_trip_stop_performance;