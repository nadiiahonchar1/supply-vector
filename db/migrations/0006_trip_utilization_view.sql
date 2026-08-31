CREATE VIEW v_trip_utilization AS
SELECT
  t.id AS trip_id,
  t.status,
  v.id AS vehicle_id,
  v.name AS vehicle_name,
  v.capacity_weight,
  v.capacity_volume,
  COALESCE(SUM(ti.quantity * p.weight_kg), 0) AS loaded_weight_kg,
  COALESCE(SUM(ti.quantity * p.volume_m3), 0) AS loaded_volume_m3,
  ROUND(
    COALESCE(SUM(ti.quantity * p.weight_kg), 0) / v.capacity_weight * 100,
    1
  ) AS weight_utilization_pct,
  CASE
    WHEN v.capacity_volume IS NOT NULL AND v.capacity_volume > 0 THEN
      ROUND(
        COALESCE(SUM(ti.quantity * p.volume_m3), 0) / v.capacity_volume * 100,
        1
      )
  END AS volume_utilization_pct
FROM trips t
JOIN vehicles v ON v.id = t.vehicle_id
LEFT JOIN trip_items ti ON ti.trip_id = t.id
LEFT JOIN transfer_requests tr ON tr.id = ti.transfer_request_id
LEFT JOIN products p ON p.id = tr.product_id
GROUP BY t.id, t.status, v.id, v.name, v.capacity_weight, v.capacity_volume;