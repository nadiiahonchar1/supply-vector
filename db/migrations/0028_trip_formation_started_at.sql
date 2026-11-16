BEGIN;

ALTER TABLE trips
ADD COLUMN formation_started_at TIMESTAMP;

UPDATE trips t
SET formation_started_at = items.first_item_at
FROM (
  SELECT
    trip_id,
    MIN(created_at) AS first_item_at
  FROM trip_items
  GROUP BY trip_id
) items
WHERE items.trip_id = t.id
  AND t.formation_started_at IS NULL;

CREATE OR REPLACE FUNCTION set_trip_formation_started_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE trips
  SET formation_started_at = COALESCE(
    formation_started_at,
    NEW.created_at,
    NOW()
  )
  WHERE id = NEW.trip_id;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_set_trip_formation_started_at
AFTER INSERT ON trip_items
FOR EACH ROW
EXECUTE FUNCTION set_trip_formation_started_at();

COMMIT;