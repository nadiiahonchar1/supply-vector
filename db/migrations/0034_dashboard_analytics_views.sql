-- =========================================================
-- 1. PRODUCT STOCK AND AVAILABILITY
-- =========================================================

CREATE OR REPLACE VIEW v_inventory_overview AS
SELECT
  sp.id AS storage_point_id,
  sp.name AS storage_point_name,
  sp.city,
  sp.status AS storage_point_status,

  p.id AS product_id,
  p.sku,
  p.name AS product_name,
  p.weight_kg,
  p.volume_m3,

  i.quantity AS physical_quantity,
  i.reserved_quantity,
  i.blocked_quantity,

  (
    i.quantity
    - i.reserved_quantity
    - i.blocked_quantity
  ) AS available_quantity,

  i.updated_at

FROM inventory i
JOIN storage_points sp
  ON sp.id = i.storage_point_id
JOIN products p
  ON p.id = i.product_id;


-- =========================================================
-- 2. GENERAL APPLICATION STATISTICS
-- =========================================================

CREATE OR REPLACE VIEW v_transfer_request_overview AS
SELECT
  tr.id,
  tr.request_number,
  tr.destination_storage_point_id,
  tr.created_by,
  tr.status,
  tr.priority,
  tr.urgent_approval_status,
  tr.created_at,
  tr.updated_at,

  COUNT(DISTINCT tri.id) AS product_count,

  COALESCE(
    SUM(tri.requested_quantity),
    0
  ) AS requested_quantity,

  COALESCE(
    SUM(tri.cancelled_quantity),
    0
  ) AS cancelled_quantity,

  COUNT(DISTINCT trs.id) AS source_allocation_count

FROM transfer_requests tr

LEFT JOIN transfer_request_items tri
  ON tri.request_id = tr.id

LEFT JOIN transfer_request_sources trs
  ON trs.transfer_request_item_id = tri.id

GROUP BY
  tr.id,
  tr.request_number,
  tr.destination_storage_point_id,
  tr.created_by,
  tr.status,
  tr.priority,
  tr.urgent_approval_status,
  tr.created_at,
  tr.updated_at;


-- =========================================================
-- 3. SHIPPING STATISTICS
-- =========================================================

CREATE OR REPLACE VIEW v_shipment_overview AS
SELECT
  s.id,
  s.shipment_number,
  s.transfer_request_id,
  s.source_storage_point_id,
  s.destination_storage_point_id,
  s.trip_id,
  s.status,
  s.created_by,
  s.created_at,

  COUNT(DISTINCT si.id) AS item_count,

  COALESCE(
    SUM(si.planned_quantity),
    0
  ) AS planned_quantity,

  COALESCE(loading.loaded_quantity, 0)
    AS loaded_quantity,

  COALESCE(receiving.received_quantity, 0)
    AS received_quantity,

  COALESCE(cargo.returned_quantity, 0)
    AS returned_quantity,

  COALESCE(cargo.lost_quantity, 0)
    AS lost_quantity,

  COALESCE(cargo.writeoff_quantity, 0)
    AS written_off_quantity,

  COALESCE(cargo.transferred_quantity, 0)
    AS responsibility_transferred_quantity

FROM shipments s

LEFT JOIN shipment_items si
  ON si.shipment_id = s.id

LEFT JOIN (
  SELECT
    si.shipment_id,
    SUM(lm.quantity) AS loaded_quantity
  FROM shipment_loading_movements lm
  JOIN shipment_items si
    ON si.id = lm.shipment_item_id
  GROUP BY si.shipment_id
) loading
  ON loading.shipment_id = s.id

LEFT JOIN (
  SELECT
    si.shipment_id,
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
  ON cargo.shipment_id = s.id

GROUP BY
  s.id,
  s.shipment_number,
  s.transfer_request_id,
  s.source_storage_point_id,
  s.destination_storage_point_id,
  s.trip_id,
  s.status,
  s.created_by,
  s.created_at,
  loading.loaded_quantity,
  receiving.received_quantity,
  cargo.returned_quantity,
  cargo.lost_quantity,
  cargo.writeoff_quantity,
  cargo.transferred_quantity;


-- =========================================================
-- 4. FLIGHT STATUS
-- =========================================================

CREATE OR REPLACE VIEW v_trip_overview AS
SELECT
  t.id,
  t.trip_number,
  t.vehicle_id,
  t.driver_id,
  t.status,
  t.planned_departure_at,
  t.actual_departure_at,
  t.completed_at,
  t.route_version,
  t.created_at,

  COUNT(DISTINCT ts.id) AS stop_count,

  COUNT(DISTINCT ts.id) FILTER (
    WHERE ts.actual_arrival_at IS NOT NULL
  ) AS arrived_stop_count,

  COUNT(DISTINCT ts.id) FILTER (
    WHERE ts.actual_departure_at IS NOT NULL
  ) AS departed_stop_count,

  COUNT(DISTINCT s.id) AS shipment_count

FROM trips t

LEFT JOIN trip_stops ts
  ON ts.trip_id = t.id

LEFT JOIN shipments s
  ON s.trip_id = t.id

GROUP BY
  t.id,
  t.trip_number,
  t.vehicle_id,
  t.driver_id,
  t.status,
  t.planned_departure_at,
  t.actual_departure_at,
  t.completed_at,
  t.route_version,
  t.created_at;


-- =========================================================
-- 5. TRAFFIC CONGESTION
-- =========================================================

CREATE OR REPLACE VIEW v_trip_cargo_utilization AS
SELECT
  t.id AS trip_id,
  t.trip_number,
  t.status AS trip_status,

  v.id AS vehicle_id,
  v.registration_number,

  v.max_weight_kg,
  v.max_volume_m3,

  COALESCE(cargo.total_weight_kg, 0)
    AS loaded_weight_kg,

  COALESCE(cargo.total_volume_m3, 0)
    AS loaded_volume_m3,

  CASE
    WHEN v.max_weight_kg IS NULL
      OR v.max_weight_kg = 0
    THEN NULL
    ELSE ROUND(
      COALESCE(cargo.total_weight_kg, 0)
      / v.max_weight_kg * 100,
      2
    )
  END AS weight_utilization_percent,

  CASE
    WHEN v.max_volume_m3 IS NULL
      OR v.max_volume_m3 = 0
    THEN NULL
    ELSE ROUND(
      COALESCE(cargo.total_volume_m3, 0)
      / v.max_volume_m3 * 100,
      2
    )
  END AS volume_utilization_percent

FROM trips t

JOIN vehicles v
  ON v.id = t.vehicle_id

LEFT JOIN (
  SELECT
    s.trip_id,

    SUM(
      lm.quantity * p.weight_kg
    ) FILTER (
      WHERE p.weight_kg IS NOT NULL
    ) AS total_weight_kg,

    SUM(
      lm.quantity * p.volume_m3
    ) FILTER (
      WHERE p.volume_m3 IS NOT NULL
    ) AS total_volume_m3

  FROM shipments s

  JOIN shipment_items si
    ON si.shipment_id = s.id

  JOIN shipment_loading_movements lm
    ON lm.shipment_item_id = si.id

  JOIN products p
    ON p.id = si.product_id

  WHERE s.trip_id IS NOT NULL

  GROUP BY s.trip_id
) cargo
  ON cargo.trip_id = t.id;


-- =========================================================
-- 6. UNRESOLVED CARGO ISSUES
-- =========================================================

CREATE OR REPLACE VIEW v_unresolved_shipment_cargo AS
SELECT
  si.id AS shipment_item_id,
  si.shipment_id,
  s.shipment_number,
  s.trip_id,
  s.status AS shipment_status,

  si.product_id,
  p.sku,
  p.name AS product_name,

  balance.loaded_quantity,
  balance.received_quantity,
  balance.returned_quantity,
  balance.lost_quantity,
  balance.writeoff_quantity,
  balance.transferred_quantity,
  balance.unresolved_quantity

FROM shipment_items si

JOIN shipments s
  ON s.id = si.shipment_id

JOIN products p
  ON p.id = si.product_id

CROSS JOIN LATERAL
  get_shipment_item_cargo_balance(si.id) balance

WHERE balance.unresolved_quantity > 0;


-- =========================================================
-- 7. DASHBOARD OVERVIEW METRICS
-- =========================================================

CREATE OR REPLACE VIEW v_dashboard_summary AS
SELECT
  (
    SELECT COUNT(*)
    FROM transfer_requests
    WHERE status = 'pending'
  ) AS pending_transfer_requests,

  (
    SELECT COUNT(*)
    FROM transfer_requests
    WHERE status = 'approved'
  ) AS approved_transfer_requests,

  (
    SELECT COUNT(*)
    FROM transfer_requests
    WHERE status = 'in_progress'
  ) AS in_progress_transfer_requests,

  (
    SELECT COUNT(*)
    FROM shipments
    WHERE status IN (
      'pending',
      'in_progress',
      'partially_delivered'
    )
  ) AS active_shipments,

  (
    SELECT COUNT(*)
    FROM trips
    WHERE status = 'planned'
  ) AS planned_trips,

  (
    SELECT COUNT(*)
    FROM trips
    WHERE status = 'ready'
  ) AS ready_trips,

  (
    SELECT COUNT(*)
    FROM trips
    WHERE status = 'in_transit'
  ) AS trips_in_transit,

  (
    SELECT COUNT(*)
    FROM trip_incidents
    WHERE occurred_at >= NOW() - INTERVAL '24 hours'
  ) AS incidents_last_24_hours,

  (
    SELECT COUNT(*)
    FROM v_unresolved_shipment_cargo
  ) AS unresolved_cargo_items,

  (
    SELECT COUNT(*)
    FROM storage_points
    WHERE status = 'unavailable'
  ) AS unavailable_storage_points,

  (
    SELECT COUNT(*)
    FROM storage_points
    WHERE status = 'closed'
  ) AS closed_storage_points;