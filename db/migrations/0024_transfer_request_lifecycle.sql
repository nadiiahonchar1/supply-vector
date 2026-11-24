-- =========================================================
-- 1. HISTORY OF APPLICATION STATUS CHANGES
-- =========================================================

CREATE TABLE transfer_request_status_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  transfer_request_id UUID NOT NULL
    REFERENCES transfer_requests(id),

  old_status TEXT,
  new_status TEXT NOT NULL,

  reason TEXT,

  changed_by UUID REFERENCES users(id),

  changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT transfer_request_status_history_status_check
    CHECK (
      new_status IN (
        'draft',
        'pending',
        'approved',
        'in_progress',
        'fulfilled',
        'partially_fulfilled',
        'cancelled'
      )
    ),

  CONSTRAINT transfer_request_status_history_old_status_check
    CHECK (
      old_status IS NULL
      OR old_status IN (
        'draft',
        'pending',
        'approved',
        'in_progress',
        'fulfilled',
        'partially_fulfilled',
        'cancelled'
      )
    )
);

CREATE INDEX transfer_request_status_history_request_idx
  ON transfer_request_status_history(
    transfer_request_id,
    changed_at DESC
  );


-- =========================================================
-- 2. THE IMMUTABILITY OF HISTORY
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_transfer_request_status_history_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION
    'Історія статусів заявки є незмінною';
END;
$$;

CREATE TRIGGER transfer_request_status_history_immutable
BEFORE UPDATE OR DELETE
ON transfer_request_status_history
FOR EACH ROW
EXECUTE FUNCTION prevent_transfer_request_status_history_mutation();


-- =========================================================
-- 3. VERIFICATION OF PERMITTED TRANSITIONS
-- =========================================================

CREATE OR REPLACE FUNCTION validate_transfer_request_status_transition()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  IF OLD.status IN (
    'fulfilled',
    'partially_fulfilled',
    'cancelled'
  ) THEN
    RAISE EXCEPTION
      'Завершена заявка не може повертатися до попереднього статусу';
  END IF;

  IF OLD.status = 'draft'
     AND NEW.status NOT IN ('pending', 'cancelled') THEN
    RAISE EXCEPTION
      'Недозволений перехід зі статусу draft';
  END IF;

  IF OLD.status = 'pending'
     AND NEW.status NOT IN ('approved', 'draft', 'cancelled') THEN
    RAISE EXCEPTION
      'Недозволений перехід зі статусу pending';
  END IF;

  IF OLD.status = 'approved'
     AND NEW.status NOT IN (
       'in_progress',
       'cancelled'
     ) THEN
    RAISE EXCEPTION
      'Недозволений перехід зі статусу approved';
  END IF;

  IF OLD.status = 'in_progress'
     AND NEW.status NOT IN (
       'fulfilled',
       'partially_fulfilled'
     ) THEN
    RAISE EXCEPTION
      'Недозволений перехід зі статусу in_progress';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER transfer_request_status_transition_guard
BEFORE UPDATE OF status
ON transfer_requests
FOR EACH ROW
EXECUTE FUNCTION validate_transfer_request_status_transition();


-- =========================================================
-- 4. AUTOMATIC RECORDING OF STATUS CHANGES
-- =========================================================

CREATE OR REPLACE FUNCTION record_transfer_request_status_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_user_id UUID;
  v_reason TEXT;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  v_user_id := NULLIF(
    current_setting('app.current_user_id', TRUE),
    ''
  )::UUID;

  v_reason := NULLIF(
    current_setting('app.status_change_reason', TRUE),
    ''
  );

  INSERT INTO transfer_request_status_history (
    transfer_request_id,
    old_status,
    new_status,
    reason,
    changed_by
  )
  VALUES (
    NEW.id,
    OLD.status,
    NEW.status,
    v_reason,
    v_user_id
  );

  RETURN NEW;
END;
$$;

CREATE TRIGGER transfer_request_status_history_insert
AFTER UPDATE OF status
ON transfer_requests
FOR EACH ROW
EXECUTE FUNCTION record_transfer_request_status_change();


-- =========================================================
-- 5. PROHIBITION ON DELETING APPLICATIONS AFTER SUBMISSION
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_transfer_request_delete_after_submission()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.status <> 'draft' THEN
    RAISE EXCEPTION
      'Видаляти можна лише чернетки заявок';
  END IF;

  RETURN OLD;
END;
$$;

CREATE TRIGGER transfer_request_delete_guard
BEFORE DELETE
ON transfer_requests
FOR EACH ROW
EXECUTE FUNCTION prevent_transfer_request_delete_after_submission();


-- =========================================================
-- 6. PROHIBITION ON CHANGING KEY FIELDS AFTER SUBMISSION
-- =========================================================

CREATE OR REPLACE FUNCTION protect_submitted_transfer_request()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.status <> 'draft' THEN
    IF NEW.destination_storage_point_id
       IS DISTINCT FROM OLD.destination_storage_point_id THEN
      RAISE EXCEPTION
        'Не можна змінювати точку призначення після подання заявки';
    END IF;

    IF NEW.created_by IS DISTINCT FROM OLD.created_by THEN
      RAISE EXCEPTION
        'Не можна змінювати автора заявки';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER transfer_request_submitted_fields_guard
BEFORE UPDATE
ON transfer_requests
FOR EACH ROW
EXECUTE FUNCTION protect_submitted_transfer_request();