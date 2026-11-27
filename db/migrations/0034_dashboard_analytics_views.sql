-- =========================================================
-- 1. INVENTORY OVERVIEW
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
-- 2. TRANSFER REQUEST OVERVIEW
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
  ON tri.transfer_request_id = tr.id

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
-- 3. SHIPMENT OVERVIEW
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

  COALESCE(cargo.loaded_quantity, 0)
    AS loaded_quantity,

  COALESCE(cargo.unloaded_quantity, 0)
    AS unloaded_before_departure_quantity,

  COALESCE(cargo.received_quantity, 0)
    AS received_quantity,

  COALESCE(cargo.returned_quantity, 0)
    AS returned_quantity,

  COALESCE(cargo.lost_quantity, 0)
    AS lost_quantity,

  COALESCE(cargo.written_off_quantity, 0)
    AS written_off_quantity,

  COALESCE(cargo.transferred_quantity, 0)
    AS responsibility_transferred_quantity,

  COALESCE(cargo.unresolved_quantity, 0)
    AS unresolved_quantity

FROM shipments s

LEFT JOIN shipment_items si
  ON si.shipment_id = s.id

LEFT JOIN (
  SELECT
    si.shipment_id,

    SUM(co.quantity) FILTER (
      WHERE co.operation_type = 'load'
    ) AS loaded_quantity,

    SUM(co.quantity) FILTER (
      WHERE co.operation_type = 'unload_before_departure'
    ) AS unloaded_quantity,

    SUM(co.quantity) FILTER (
      WHERE co.operation_type = 'receive'
    ) AS received_quantity,

    SUM(co.quantity) FILTER (
      WHERE co.operation_type = 'return'
    ) AS returned_quantity,

    SUM(co.quantity) FILTER (
      WHERE co.operation_type = 'loss'
    ) AS lost_quantity,

    SUM(co.quantity) FILTER (
      WHERE co.operation_type = 'writeoff'
    ) AS written_off_quantity,

    SUM(co.quantity) FILTER (
      WHERE co.operation_type = 'responsibility_transfer'
    ) AS transferred_quantity,

    (
      COALESCE(
        SUM(co.quantity) FILTER (
          WHERE co.operation_type = 'load'
        ),
        0
      )
      -
      COALESCE(
        SUM(co.quantity) FILTER (
          WHERE co.operation_type IN (
            'unload_before_departure',
            'receive',
            'return',
            'loss',
            'writeoff'
          )
        ),
        0
      )
    ) AS unresolved_quantity

  FROM shipment_items si

  LEFT JOIN shipment_cargo_operations co
    ON co.shipment_item_id = si.id

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
  cargo.loaded_quantity,
  cargo.unloaded_quantity,
  cargo.received_quantity,
  cargo.returned_quantity,
  cargo.lost_quantity,
  cargo.written_off_quantity,
  cargo.transferred_quantity,
  cargo.unresolved_quantity;


-- =========================================================
-- 4. TRIP OVERVIEW
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

  COUNT(DISTINCT s.id) AS shipment_count,

  COUNT(DISTINCT ti.id) AS incident_count

FROM trips t

LEFT JOIN trip_stops ts
  ON ts.trip_id = t.id

LEFT JOIN shipments s
  ON s.trip_id = t.id

LEFT JOIN trip_incidents ti
  ON ti.trip_id = t.id

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
-- 5. TRIP CARGO UTILIZATION
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

  COALESCE(cargo.loaded_weight_kg, 0)
    AS loaded_weight_kg,

  COALESCE(cargo.loaded_volume_m3, 0)
    AS loaded_volume_m3,

  CASE
    WHEN v.max_weight_kg IS NULL
      OR v.max_weight_kg <= 0
    THEN NULL
    ELSE ROUND(
      COALESCE(cargo.loaded_weight_kg, 0)
      / v.max_weight_kg * 100,
      2
    )
  END AS weight_utilization_percent,

  CASE
    WHEN v.max_volume_m3 IS NULL
      OR v.max_volume_m3 <= 0
    THEN NULL
    ELSE ROUND(
      COALESCE(cargo.loaded_volume_m3, 0)
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
      (
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
        END
      ) * p.weight_kg
    ) FILTER (
      WHERE p.weight_kg IS NOT NULL
    ) AS loaded_weight_kg,

    SUM(
      (
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
        END
      ) * p.volume_m3
    ) FILTER (
      WHERE p.volume_m3 IS NOT NULL
    ) AS loaded_volume_m3

  FROM shipments s

  JOIN shipment_items si
    ON si.shipment_id = s.id

  JOIN products p
    ON p.id = si.product_id

  JOIN shipment_cargo_operations co
    ON co.shipment_item_id = si.id

  WHERE s.trip_id IS NOT NULL

  GROUP BY s.trip_id
) cargo
  ON cargo.trip_id = t.id;


-- =========================================================
-- 6. UNRESOLVED SHIPMENT CARGO
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
  balance.unloaded_quantity,
  balance.received_quantity,
  balance.returned_quantity,
  balance.lost_quantity,
  balance.written_off_quantity,
  balance.transferred_quantity,
  balance.unresolved_quantity

FROM shipment_items si

JOIN shipments s
  ON s.id = si.shipment_id

JOIN products p
  ON p.id = si.product_id

CROSS JOIN LATERAL (
  SELECT
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
    ) AS unloaded_quantity,

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
    ) AS transferred_quantity,

    (
      COALESCE(
        SUM(co.quantity) FILTER (
          WHERE co.operation_type = 'load'
        ),
        0
      )
      -
      COALESCE(
        SUM(co.quantity) FILTER (
          WHERE co.operation_type IN (
            'unload_before_departure',
            'receive',
            'return',
            'loss',
            'writeoff'
          )
        ),
        0
      )
    ) AS unresolved_quantity

  FROM shipment_cargo_operations co
  WHERE co.shipment_item_id = si.id
) balance

WHERE balance.unresolved_quantity > 0;


-- =========================================================
-- 7. DASHBOARD SUMMARY
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
    WHERE status IN ('pending', 'in_transit')
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