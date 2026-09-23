CREATE UNIQUE INDEX IF NOT EXISTS idx_trips_one_active_trip_per_vehicle
ON trips (vehicle_id)
WHERE status IN ('ready', 'in_transit');