-- =========================================================
-- 1. SHIPMENT DELIVERY PERFORMANCE
-- =========================================================

CREATE OR REPLACE VIEW v_shipment_delivery_performance AS
WITH cargo AS (
  SELECT
    si.shipment_id,

    MIN(co.occurred_at) FILTER (
      WHERE co.operation_type = 'receive'
    ) AS first_received_at,

    MAX(co.occurred_at) FILTER (
      WHERE co.operation_type = 'receive'
    ) AS last_received_at,

    COALESCE(
      SUM(co.quantity) FILTER (
        WHERE co.operation_type = 'load'
      ),
      0
    ) AS loaded_quantity,

    COALESCE(
      SUM(co.quantity) FILTER (
        WHERE co.operation_type = 'unload_before_departure'
      ),
      0
    ) AS unloaded_before_departure_quantity,

    COALESCE(
      SUM(co.quantity) FILTER (
        WHERE co.operation_type = 'receive'
      ),
      0
    ) AS received_quantity,

    COALESCE(
      SUM(co.quantity) FILTER (
        WHERE co.operation_type = 'return'
      ),
      0
    ) AS returned_quantity,

    COALESCE(
      SUM(co.quantity) FILTER (
        WHERE co.operation_type = 'loss'
      ),
      0
    ) AS lost_quantity,

    COALESCE(
      SUM(co.quantity) FILTER (
        WHERE co.operation_type = 'writeoff'
      ),
      0
    ) AS written_off_quantity,

    COALESCE(
      SUM(co.quantity) FILTER (
        WHERE co.operation_type = 'responsibility_transfer'
      ),
      0
    ) AS transferred_quantity

  FROM shipment_items si

  LEFT JOIN shipment_cargo_operations co
    ON co.shipment_item_id = si.id

  GROUP BY si.shipment_id
),
shipment_cargo AS (
  SELECT
    shipment_id,

    SUM(loaded_quantity) AS loaded_quantity,
    SUM(unloaded_before_departure_quantity)
      AS unloaded_before_departure_quantity,
    SUM(received_quantity) AS received_quantity,
    SUM(returned_quantity) AS returned_quantity,
    SUM(lost_quantity) AS lost_quantity,
    SUM(written_off_quantity) AS written_off_quantity,
    SUM(transferred_quantity) AS transferred_quantity,

    MIN(first_received_at) AS first_received_at,
    MAX(last_received_at) AS last_received_at

  FROM cargo
  GROUP BY shipment_id
)
SELECT
  s.id AS shipment_id,
  s.shipment_number,
  s.transfer_request_id,
  s.trip_id,
  s.source_storage_point_id,
  s.destination_storage_point_id,
  s.status,
  s.created_at,

  t.actual_departure_at,

  c.first_received_at,
  c.last_received_at,

  CASE
    WHEN t.actual_departure_at IS NOT NULL
      AND c.last_received_at IS NOT NULL
    THEN ROUND(
      (
        EXTRACT(
          EPOCH FROM (
            c.last_received_at - t.actual_departure_at
          )
        ) / 3600
      )::NUMERIC,
      2
    )
    ELSE NULL
  END AS delivery_duration_hours,

  COALESCE(c.loaded_quantity, 0) AS loaded_quantity,

  COALESCE(
    c.unloaded_before_departure_quantity,
    0
  ) AS unloaded_before_departure_quantity,

  COALESCE(c.received_quantity, 0) AS received_quantity,

  COALESCE(c.returned_quantity, 0) AS returned_quantity,

  COALESCE(c.lost_quantity, 0) AS lost_quantity,

  COALESCE(c.written_off_quantity, 0)
    AS written_off_quantity,

  COALESCE(c.transferred_quantity, 0)
    AS responsibility_transferred_quantity,

  (
    COALESCE(c.loaded_quantity, 0)
    - COALESCE(c.unloaded_before_departure_quantity, 0)
    - COALESCE(c.received_quantity, 0)
    - COALESCE(c.returned_quantity, 0)
    - COALESCE(c.lost_quantity, 0)
    - COALESCE(c.written_off_quantity, 0)
  ) AS unresolved_quantity

FROM shipments s

LEFT JOIN trips t
  ON t.id = s.trip_id

LEFT JOIN shipment_cargo c
  ON c.shipment_id = s.id;


-- =========================================================
-- 2. TRIP STOP ARRIVAL PERFORMANCE
-- =========================================================

CREATE OR REPLACE VIEW v_trip_stop_performance AS
SELECT
  ts.id AS trip_stop_id,
  ts.trip_id,
  t.trip_number,

  ts.storage_point_id,
  sp.name AS storage_point_name,

  ts.sequence_number,

  ts.planned_arrival_at,
  ts.actual_arrival_at,

  CASE
    WHEN ts.planned_arrival_at IS NOT NULL
      AND ts.actual_arrival_at IS NOT NULL
    THEN ROUND(
      (
        EXTRACT(
          EPOCH FROM (
            ts.actual_arrival_at - ts.planned_arrival_at
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
-- 3. PARTIAL DELIVERY ANALYTICS
-- =========================================================

CREATE OR REPLACE VIEW v_partial_delivery_analytics AS
WITH item_cargo AS (
  SELECT
    si.id AS shipment_item_id,
    si.shipment_id,
    si.product_id,
    si.planned_quantity,

    COALESCE(
      SUM(co.quantity) FILTER (
        WHERE co.operation_type = 'load'
      ),
      0
    ) AS loaded_quantity,

    COALESCE(
      SUM(co.quantity) FILTER (
        WHERE co.operation_type = 'unload_before_departure'
      ),
      0
    ) AS unloaded_before_departure_quantity,

    COALESCE(
      SUM(co.quantity) FILTER (
        WHERE co.operation_type = 'receive'
      ),
      0
    ) AS received_quantity,

    COALESCE(
      SUM(co.quantity) FILTER (
        WHERE co.operation_type = 'return'
      ),
      0
    ) AS returned_quantity,

    COALESCE(
      SUM(co.quantity) FILTER (
        WHERE co.operation_type = 'loss'
      ),
      0
    ) AS lost_quantity,

    COALESCE(
      SUM(co.quantity) FILTER (
        WHERE co.operation_type = 'writeoff'
      ),
      0
    ) AS written_off_quantity,

    COALESCE(
      SUM(co.quantity) FILTER (
        WHERE co.operation_type = 'responsibility_transfer'
      ),
      0
    ) AS transferred_quantity

  FROM shipment_items si

  LEFT JOIN shipment_cargo_operations co
    ON co.shipment_item_id = si.id

  GROUP BY
    si.id,
    si.shipment_id,
    si.product_id,
    si.planned_quantity
)
SELECT
  s.id AS shipment_id,
  s.shipment_number,
  s.trip_id,
  s.transfer_request_id,
  s.status,

  COUNT(ic.shipment_item_id) AS item_count,

  SUM(ic.planned_quantity) AS planned_quantity,

  SUM(ic.loaded_quantity) AS loaded_quantity,

  SUM(ic.unloaded_before_departure_quantity)
    AS unloaded_before_departure_quantity,

  SUM(ic.received_quantity) AS received_quantity,

  SUM(ic.returned_quantity) AS returned_quantity,

  SUM(ic.lost_quantity) AS lost_quantity,

  SUM(ic.written_off_quantity) AS written_off_quantity,

  SUM(ic.transferred_quantity)
    AS responsibility_transferred_quantity,

  SUM(
    ic.loaded_quantity
    - ic.unloaded_before_departure_quantity
    - ic.received_quantity
    - ic.returned_quantity
    - ic.lost_quantity
    - ic.written_off_quantity
  ) AS unresolved_quantity

FROM shipments s

JOIN item_cargo ic
  ON ic.shipment_id = s.id

GROUP BY
  s.id,
  s.shipment_number,
  s.trip_id,
  s.transfer_request_id,
  s.status

HAVING
  SUM(ic.received_quantity) > 0
  AND SUM(ic.received_quantity) < SUM(ic.planned_quantity);


-- =========================================================
-- 4. INVENTORY ADJUSTMENT ANALYTICS
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
-- 5. PEAK CARGO UTILIZATION BY TRIP
-- =========================================================

CREATE OR REPLACE VIEW v_trip_peak_cargo_utilization AS
WITH cargo_events AS (
  SELECT
    s.trip_id,
    co.id AS operation_id,
    co.occurred_at,
    si.product_id,

    CASE
      WHEN co.operation_type = 'load'
      THEN co.quantity

      WHEN co.operation_type IN (
        'unload_before_departure',
        'receive',
        'return',
        'loss',
        'writeoff'
      )
      THEN -co.quantity

      ELSE 0
    END AS quantity_delta,

    p.weight_kg,
    p.volume_m3

  FROM shipment_cargo_operations co

  JOIN shipment_items si
    ON si.id = co.shipment_item_id

  JOIN shipments s
    ON s.id = si.shipment_id

  JOIN products p
    ON p.id = si.product_id

  WHERE s.trip_id IS NOT NULL
),
trip_running_load AS (
  SELECT
    trip_id,
    operation_id,
    occurred_at,

    SUM(
      quantity_delta * weight_kg
    ) OVER (
      PARTITION BY trip_id
      ORDER BY occurred_at, operation_id
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS current_weight_kg,

    SUM(
      quantity_delta * volume_m3
    ) OVER (
      PARTITION BY trip_id
      ORDER BY occurred_at, operation_id
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS current_volume_m3

  FROM cargo_events
),
trip_peak_load AS (
  SELECT
    trip_id,

    MAX(current_weight_kg) AS peak_weight_kg,

    MAX(current_volume_m3) AS peak_volume_m3

  FROM trip_running_load
  GROUP BY trip_id
),
trip_attribute_completeness AS (
  SELECT
    trip_id,

    BOOL_OR(weight_kg IS NULL)
      AS has_missing_weight,

    BOOL_OR(volume_m3 IS NULL)
      AS has_missing_volume

  FROM cargo_events
  WHERE quantity_delta > 0
  GROUP BY trip_id
)
SELECT
  t.id AS trip_id,
  t.trip_number,
  t.status AS trip_status,

  v.id AS vehicle_id,
  v.registration_number,
  v.brand,
  v.model,

  v.max_weight_kg,
  v.max_volume_m3,

  CASE
    WHEN COALESCE(c.has_missing_weight, FALSE)
    THEN NULL
    ELSE COALESCE(p.peak_weight_kg, 0)
  END AS peak_weight_kg,

  CASE
    WHEN COALESCE(c.has_missing_volume, FALSE)
    THEN NULL
    ELSE COALESCE(p.peak_volume_m3, 0)
  END AS peak_volume_m3,

  CASE
    WHEN COALESCE(c.has_missing_weight, FALSE)
    THEN NULL
    ELSE ROUND(
      COALESCE(p.peak_weight_kg, 0)
      / v.max_weight_kg * 100,
      2
    )
  END AS peak_weight_utilization_percent,

  CASE
    WHEN COALESCE(c.has_missing_volume, FALSE)
    THEN NULL
    ELSE ROUND(
      COALESCE(p.peak_volume_m3, 0)
      / v.max_volume_m3 * 100,
      2
    )
  END AS peak_volume_utilization_percent

FROM trips t

JOIN vehicles v
  ON v.id = t.vehicle_id

LEFT JOIN trip_peak_load p
  ON p.trip_id = t.id

LEFT JOIN trip_attribute_completeness c
  ON c.trip_id = t.id;


-- =========================================================
-- 6. VEHICLE UTILIZATION ANALYTICS
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

  ROUND(
    AVG(
      u.peak_weight_utilization_percent
    ) FILTER (
      WHERE u.peak_weight_utilization_percent IS NOT NULL
    ),
    2
  ) AS average_peak_weight_utilization_percent,

  ROUND(
    AVG(
      u.peak_volume_utilization_percent
    ) FILTER (
      WHERE u.peak_volume_utilization_percent IS NOT NULL
    ),
    2
  ) AS average_peak_volume_utilization_percent

FROM vehicles v

LEFT JOIN trips t
  ON t.vehicle_id = v.id

LEFT JOIN v_trip_peak_cargo_utilization u
  ON u.trip_id = t.id

GROUP BY
  v.id,
  v.registration_number,
  v.brand,
  v.model,
  v.max_weight_kg,
  v.max_volume_m3;


-- =========================================================
-- 7. DELIVERY PERFORMANCE SUMMARY
-- =========================================================

CREATE OR REPLACE VIEW v_delivery_performance_summary AS
SELECT
  COUNT(*) AS total_shipments,

  COUNT(*) FILTER (
    WHERE status = 'completed'
  ) AS completed_shipments,

  COUNT(*) FILTER (
    WHERE status = 'cancelled'
  ) AS cancelled_shipments,

  COUNT(*) FILTER (
    WHERE status = 'in_transit'
  ) AS in_transit_shipments,

  COUNT(*) FILTER (
    WHERE status = 'pending'
  ) AS pending_shipments,

  (
    SELECT COUNT(*)
    FROM v_partial_delivery_analytics
  ) AS partially_received_shipments,

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
-- 8. ARRIVAL PERFORMANCE SUMMARY
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