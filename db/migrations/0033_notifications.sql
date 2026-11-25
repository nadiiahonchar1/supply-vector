-- =========================================================
-- 1. NOTIFICATION TABLE
-- =========================================================

CREATE TABLE notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  user_id UUID NOT NULL REFERENCES users(id),

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
-- 3. CREATING A NOTIFICATION
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
    RAISE EXCEPTION 'Необхідно вказати отримувача сповіщення';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM users
    WHERE id = p_user_id
      AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION
      'Отримувач не існує або його обліковий запис неактивний';
  END IF;

  IF p_notification_type NOT IN (
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
    RAISE EXCEPTION 'Невідомий тип сповіщення';
  END IF;

  IF p_priority NOT IN ('low', 'normal', 'high', 'urgent') THEN
    RAISE EXCEPTION 'Невідомий пріоритет сповіщення';
  END IF;

  IF p_title IS NULL
     OR LENGTH(TRIM(p_title)) = 0
     OR LENGTH(p_title) > 200 THEN
    RAISE EXCEPTION
      'Заголовок сповіщення обов’язковий (до 200 символів)';
  END IF;

  IF p_message IS NULL
     OR LENGTH(TRIM(p_message)) = 0
     OR LENGTH(p_message) > 2000 THEN
    RAISE EXCEPTION
      'Текст сповіщення обов’язковий (до 2000 символів)';
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
    p_reference_type,
    p_reference_id,
    p_deduplication_key
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
      AND deduplication_key = p_deduplication_key;
  END IF;

  RETURN v_notification_id;
END;
$$;


-- =========================================================
-- 4. MARKING A NOTIFICATION AS READ
-- =========================================================

CREATE OR REPLACE FUNCTION mark_notification_as_read(
  p_notification_id UUID,
  p_user_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
  v_updated BOOLEAN;
BEGIN
  UPDATE notifications
  SET
    is_read = TRUE,
    read_at = COALESCE(read_at, NOW())
  WHERE id = p_notification_id
    AND user_id = p_user_id
    AND is_read = FALSE;

  v_updated := FOUND;

  RETURN v_updated;
END;
$$;


-- =========================================================
-- 5. MARK ALL NOTIFICATIONS AS READ
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
-- 6. NUMBER OF UNREAD NOTIFICATIONS
-- =========================================================

CREATE OR REPLACE FUNCTION get_unread_notification_count(
  p_user_id UUID
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
  SELECT COUNT(*)
  FROM notifications
  WHERE user_id = p_user_id
    AND is_read = FALSE;
$$;


-- =========================================================
-- 7. PROTECTION AGAINST MODIFICATION OF THIRD-PARTY NOTIFICATIONS
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
    RAISE EXCEPTION
      'Вміст і отримувача сповіщення не можна змінювати';
  END IF;

  IF OLD.is_read = TRUE AND NEW.is_read = FALSE THEN
    RAISE EXCEPTION
      'Прочитане сповіщення не можна повернути до непрочитаного стану';
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
-- 8. PROHIBITION ON DELETING NOTIFICATIONS
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_notification_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION
    'Сповіщення не можна видаляти';
END;
$$;

CREATE TRIGGER notifications_delete_guard
BEFORE DELETE
ON notifications
FOR EACH ROW
EXECUTE FUNCTION prevent_notification_delete();