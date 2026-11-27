-- =========================================================
-- 1. NOTIFICATIONS
-- =========================================================

CREATE TABLE notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  user_id UUID NOT NULL
    REFERENCES users(id) ON DELETE RESTRICT,

  notification_type TEXT NOT NULL,

  title TEXT NOT NULL,

  message TEXT NOT NULL,

  priority TEXT NOT NULL DEFAULT 'normal',

  reference_type TEXT,

  reference_id UUID,

  deduplication_key TEXT,

  is_read BOOLEAN NOT NULL DEFAULT FALSE,

  read_at TIMESTAMPTZ,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT notifications_type_check
    CHECK (
      notification_type IN (
        'transfer_request_submitted',
        'transfer_request_approved',
        'transfer_request_returned',
        'transfer_request_cancelled',
        'urgent_priority_decision',
        'shipment_created',
        'shipment_status_changed',
        'trip_assigned',
        'trip_route_changed',
        'trip_delayed',
        'trip_incident_reported',
        'shipment_received',
        'inventory_discrepancy',
        'cargo_responsibility_transferred',
        'salvage_request_created',
        'salvage_request_decided',
        'general'
      )
    ),

  CONSTRAINT notifications_priority_check
    CHECK (
      priority IN ('low', 'normal', 'high', 'urgent')
    ),

  CONSTRAINT notifications_title_check
    CHECK (
      LENGTH(TRIM(title)) BETWEEN 1 AND 200
    ),

  CONSTRAINT notifications_message_check
    CHECK (
      LENGTH(TRIM(message)) BETWEEN 1 AND 2000
    ),

  CONSTRAINT notifications_reference_type_check
    CHECK (
      reference_type IS NULL
      OR LENGTH(TRIM(reference_type)) BETWEEN 1 AND 50
    ),

  CONSTRAINT notifications_reference_pair_check
    CHECK (
      (reference_type IS NULL AND reference_id IS NULL)
      OR
      (reference_type IS NOT NULL AND reference_id IS NOT NULL)
    ),

  CONSTRAINT notifications_deduplication_key_check
    CHECK (
      deduplication_key IS NULL
      OR LENGTH(TRIM(deduplication_key)) BETWEEN 1 AND 200
    ),

  CONSTRAINT notifications_read_state_check
    CHECK (
      (is_read = FALSE AND read_at IS NULL)
      OR
      (is_read = TRUE AND read_at IS NOT NULL)
    )
);


-- =========================================================
-- 2. INDEXES
-- =========================================================

CREATE INDEX notifications_user_created_idx
  ON notifications(user_id, created_at DESC);

CREATE INDEX notifications_user_unread_idx
  ON notifications(user_id, created_at DESC)
  WHERE is_read = FALSE;

CREATE INDEX notifications_reference_idx
  ON notifications(reference_type, reference_id)
  WHERE reference_id IS NOT NULL;

CREATE UNIQUE INDEX notifications_deduplication_idx
  ON notifications(user_id, deduplication_key)
  WHERE deduplication_key IS NOT NULL;


-- =========================================================
-- 3. CREATE A NOTIFICATION
-- =========================================================

CREATE OR REPLACE FUNCTION create_notification(
  p_user_id UUID,
  p_notification_type TEXT,
  p_title TEXT,
  p_message TEXT,
  p_priority TEXT DEFAULT 'normal',
  p_reference_type TEXT DEFAULT NULL,
  p_reference_id UUID DEFAULT NULL,
  p_deduplication_key TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_notification_id UUID;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'notification_recipient_required';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM users
    WHERE id = p_user_id
      AND is_active = TRUE
      AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'notification_recipient_unavailable';
  END IF;

  IF p_notification_type IS NULL
     OR p_notification_type NOT IN (
       'transfer_request_submitted',
       'transfer_request_approved',
       'transfer_request_returned',
       'transfer_request_cancelled',
       'urgent_priority_decision',
       'shipment_created',
       'shipment_status_changed',
       'trip_assigned',
       'trip_route_changed',
       'trip_delayed',
       'trip_incident_reported',
       'shipment_received',
       'inventory_discrepancy',
       'cargo_responsibility_transferred',
       'salvage_request_created',
       'salvage_request_decided',
       'general'
     ) THEN
    RAISE EXCEPTION 'invalid_notification_type';
  END IF;

  IF p_priority IS NULL
     OR p_priority NOT IN ('low', 'normal', 'high', 'urgent') THEN
    RAISE EXCEPTION 'invalid_notification_priority';
  END IF;

  IF p_title IS NULL
     OR LENGTH(TRIM(p_title)) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'invalid_notification_title';
  END IF;

  IF p_message IS NULL
     OR LENGTH(TRIM(p_message)) NOT BETWEEN 1 AND 2000 THEN
    RAISE EXCEPTION 'invalid_notification_message';
  END IF;

  IF p_reference_type IS NOT NULL
     AND LENGTH(TRIM(p_reference_type)) NOT BETWEEN 1 AND 50 THEN
    RAISE EXCEPTION 'invalid_notification_reference_type';
  END IF;

  IF (p_reference_type IS NULL) <> (p_reference_id IS NULL) THEN
    RAISE EXCEPTION 'notification_reference_mismatch';
  END IF;

  IF p_deduplication_key IS NOT NULL
     AND LENGTH(TRIM(p_deduplication_key)) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'invalid_notification_deduplication_key';
  END IF;

  INSERT INTO notifications (
    user_id,
    notification_type,
    title,
    message,
    priority,
    reference_type,
    reference_id,
    deduplication_key
  )
  VALUES (
    p_user_id,
    p_notification_type,
    TRIM(p_title),
    TRIM(p_message),
    p_priority,
    CASE
      WHEN p_reference_type IS NULL THEN NULL
      ELSE TRIM(p_reference_type)
    END,
    p_reference_id,
    CASE
      WHEN p_deduplication_key IS NULL THEN NULL
      ELSE TRIM(p_deduplication_key)
    END
  )
  ON CONFLICT (user_id, deduplication_key)
    WHERE deduplication_key IS NOT NULL
  DO NOTHING
  RETURNING id INTO v_notification_id;

  IF v_notification_id IS NULL
     AND p_deduplication_key IS NOT NULL THEN

    SELECT id
    INTO v_notification_id
    FROM notifications
    WHERE user_id = p_user_id
      AND deduplication_key = TRIM(p_deduplication_key);
  END IF;

  IF v_notification_id IS NULL THEN
    RAISE EXCEPTION 'notification_creation_failed';
  END IF;

  RETURN v_notification_id;
END;
$$;


-- =========================================================
-- 4. MARK ONE NOTIFICATION AS READ
-- =========================================================

CREATE OR REPLACE FUNCTION mark_notification_as_read(
  p_notification_id UUID,
  p_user_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
  IF p_notification_id IS NULL OR p_user_id IS NULL THEN
    RAISE EXCEPTION 'notification_parameters_required';
  END IF;

  UPDATE notifications
  SET
    is_read = TRUE,
    read_at = NOW()
  WHERE id = p_notification_id
    AND user_id = p_user_id
    AND is_read = FALSE;

  RETURN FOUND;
END;
$$;


-- =========================================================
-- 5. MARK ALL USER NOTIFICATIONS AS READ
-- =========================================================

CREATE OR REPLACE FUNCTION mark_all_notifications_as_read(
  p_user_id UUID
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_updated_count INTEGER;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'notification_user_required';
  END IF;

  UPDATE notifications
  SET
    is_read = TRUE,
    read_at = NOW()
  WHERE user_id = p_user_id
    AND is_read = FALSE;

  GET DIAGNOSTICS v_updated_count = ROW_COUNT;

  RETURN v_updated_count;
END;
$$;


-- =========================================================
-- 6. GET UNREAD NOTIFICATION COUNT
-- =========================================================

CREATE OR REPLACE FUNCTION get_unread_notification_count(
  p_user_id UUID
)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_count BIGINT;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'notification_user_required';
  END IF;

  SELECT COUNT(*)
  INTO v_count
  FROM notifications
  WHERE user_id = p_user_id
    AND is_read = FALSE;

  RETURN v_count;
END;
$$;


-- =========================================================
-- 7. PROTECT NOTIFICATION CONTENT AND READ STATE
-- =========================================================

CREATE OR REPLACE FUNCTION validate_notification_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.user_id IS DISTINCT FROM OLD.user_id
     OR NEW.notification_type IS DISTINCT FROM OLD.notification_type
     OR NEW.title IS DISTINCT FROM OLD.title
     OR NEW.message IS DISTINCT FROM OLD.message
     OR NEW.priority IS DISTINCT FROM OLD.priority
     OR NEW.reference_type IS DISTINCT FROM OLD.reference_type
     OR NEW.reference_id IS DISTINCT FROM OLD.reference_id
     OR NEW.deduplication_key IS DISTINCT FROM OLD.deduplication_key
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'notification_content_is_immutable';
  END IF;

  IF OLD.is_read = TRUE THEN
    IF NEW.is_read IS DISTINCT FROM OLD.is_read
       OR NEW.read_at IS DISTINCT FROM OLD.read_at THEN
      RAISE EXCEPTION 'notification_read_state_is_final';
    END IF;

    RETURN NEW;
  END IF;

  IF NEW.is_read = FALSE AND NEW.read_at IS NOT NULL THEN
    RAISE EXCEPTION 'invalid_notification_read_state';
  END IF;

  IF NEW.is_read = TRUE AND NEW.read_at IS NULL THEN
    RAISE EXCEPTION 'notification_read_timestamp_required';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER notifications_update_guard
BEFORE UPDATE
ON notifications
FOR EACH ROW
EXECUTE FUNCTION validate_notification_update();


-- =========================================================
-- 8. PREVENT NOTIFICATION DELETION
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_notification_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'notification_deletion_not_allowed';
END;
$$;

CREATE TRIGGER notifications_delete_guard
BEFORE DELETE
ON notifications
FOR EACH ROW
EXECUTE FUNCTION prevent_notification_delete();