-- =========================================================
-- 1. LOG OF DECISIONS ON APPLICATIONS
-- =========================================================

CREATE TABLE salvage_request_decisions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  salvage_request_id UUID NOT NULL
    REFERENCES salvage_requests(id),

  decision TEXT NOT NULL,

  decided_by UUID NOT NULL
    REFERENCES users(id),

  reason TEXT NOT NULL,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT salvage_request_decision_type_check
    CHECK (
      decision IN ('rejected', 'cancelled')
    ),

  CONSTRAINT salvage_request_decision_reason_check
    CHECK (
      LENGTH(TRIM(reason)) > 0
      AND LENGTH(reason) <= 2000
    )
);

CREATE INDEX salvage_request_decisions_history_idx
  ON salvage_request_decisions(
    salvage_request_id,
    created_at DESC
  );


-- =========================================================
-- 2. PROHIBITION ON ALTERING THE HISTORY OF DECISIONS
-- =========================================================

CREATE OR REPLACE FUNCTION prevent_salvage_decision_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION
    'Історію рішень щодо спеціальних заявок не можна змінювати';
END;
$$;

CREATE TRIGGER salvage_request_decisions_immutable
BEFORE UPDATE OR DELETE
ON salvage_request_decisions
FOR EACH ROW
EXECUTE FUNCTION prevent_salvage_decision_mutation();


-- =========================================================
-- 3. REJECTION OF AN APPLICATION
-- =========================================================

CREATE OR REPLACE FUNCTION reject_salvage_request(
  p_request_id UUID,
  p_user_id UUID,
  p_reason TEXT
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_request RECORD;
BEGIN
  PERFORM assert_salvage_approval_permission(p_user_id);

  IF p_reason IS NULL
     OR LENGTH(TRIM(p_reason)) = 0
     OR LENGTH(p_reason) > 2000 THEN
    RAISE EXCEPTION
      'Необхідно вказати причину відхилення';
  END IF;

  SELECT *
  INTO v_request
  FROM salvage_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Заявку не знайдено';
  END IF;

  IF v_request.status <> 'pending' THEN
    RAISE EXCEPTION
      'Відхилити можна лише заявку зі статусом pending';
  END IF;

  INSERT INTO salvage_request_decisions (
    salvage_request_id,
    decision,
    decided_by,
    reason
  )
  VALUES (
    p_request_id,
    'rejected',
    p_user_id,
    TRIM(p_reason)
  );

  UPDATE salvage_requests
  SET
    status = 'rejected',
    updated_at = NOW()
  WHERE id = p_request_id;

  INSERT INTO salvage_request_status_history (
    salvage_request_id,
    old_status,
    new_status,
    changed_by,
    reason
  )
  VALUES (
    p_request_id,
    'pending',
    'rejected',
    p_user_id,
    TRIM(p_reason)
  );

  RETURN p_request_id;
END;
$$;


-- =========================================================
-- 4. CANCELLATION OF AN APPROVED APPLICATION
-- =========================================================

CREATE OR REPLACE FUNCTION cancel_salvage_request(
  p_request_id UUID,
  p_user_id UUID,
  p_reason TEXT
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_request RECORD;
  v_reservation RECORD;
  v_remaining INTEGER;
BEGIN
  PERFORM assert_salvage_approval_permission(p_user_id);

  IF p_reason IS NULL
     OR LENGTH(TRIM(p_reason)) = 0
     OR LENGTH(p_reason) > 2000 THEN
    RAISE EXCEPTION
      'Необхідно вказати причину скасування';
  END IF;

  SELECT *
  INTO v_request
  FROM salvage_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Заявку не знайдено';
  END IF;

  IF v_request.status NOT IN ('approved', 'in_progress') THEN
    RAISE EXCEPTION
      'Скасувати можна лише погоджену заявку, яка ще виконується';
  END IF;

  FOR v_reservation IN
    SELECT
      ir.id,
      ir.reserved_quantity,
      ir.consumed_quantity,
      ir.released_quantity
    FROM inventory_reservations ir
    JOIN salvage_request_items sri
      ON sri.id = ir.salvage_request_item_id
    WHERE sri.salvage_request_id = p_request_id
    ORDER BY ir.id
    FOR UPDATE OF ir
  LOOP
    v_remaining :=
      v_reservation.reserved_quantity
      - v_reservation.consumed_quantity
      - v_reservation.released_quantity;

    IF v_remaining > 0 THEN
      PERFORM release_inventory_reservation(
        v_reservation.id,
        v_remaining,
        p_user_id,
        TRIM(p_reason)
      );
    END IF;
  END LOOP;

  INSERT INTO salvage_request_decisions (
    salvage_request_id,
    decision,
    decided_by,
    reason
  )
  VALUES (
    p_request_id,
    'cancelled',
    p_user_id,
    TRIM(p_reason)
  );

  UPDATE salvage_requests
  SET
    status = 'cancelled',
    updated_at = NOW()
  WHERE id = p_request_id;

  INSERT INTO salvage_request_status_history (
    salvage_request_id,
    old_status,
    new_status,
    changed_by,
    reason
  )
  VALUES (
    p_request_id,
    v_request.status,
    'cancelled',
    p_user_id,
    TRIM(p_reason)
  );

  RETURN p_request_id;
END;
$$;


-- =========================================================
-- 5. PROHIBITION OF DIRECT TRANSITION TO REJECTED/CANCELLED
-- =========================================================

CREATE OR REPLACE FUNCTION guard_salvage_terminal_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status
     AND NEW.status IN ('rejected', 'cancelled') THEN

    IF NOT EXISTS (
      SELECT 1
      FROM salvage_request_decisions d
      WHERE d.salvage_request_id = NEW.id
        AND d.decision = NEW.status
    ) THEN
      RAISE EXCEPTION
        'Відхилення або скасування можливе лише через спеціальну функцію';
    END IF;

  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER salvage_terminal_status_guard
BEFORE UPDATE OF status
ON salvage_requests
FOR EACH ROW
EXECUTE FUNCTION guard_salvage_terminal_status();


-- =========================================================
-- 6. MONITORING OF REMAINING RESERVES AFTER CANCELLATION
-- =========================================================

CREATE OR REPLACE VIEW v_salvage_request_cancellation_status AS
SELECT
  r.id AS salvage_request_id,
  r.request_number,
  r.status,

  COUNT(DISTINCT sri.id) AS item_count,

  COALESCE(
    SUM(ir.reserved_quantity),
    0
  ) AS total_reserved_quantity,

  COALESCE(
    SUM(ir.consumed_quantity),
    0
  ) AS total_consumed_quantity,

  COALESCE(
    SUM(ir.released_quantity),
    0
  ) AS total_released_quantity,

  COALESCE(
    SUM(
      ir.reserved_quantity
      - ir.consumed_quantity
      - ir.released_quantity
    ),
    0
  ) AS remaining_reserved_quantity

FROM salvage_requests r

LEFT JOIN salvage_request_items sri
  ON sri.salvage_request_id = r.id

LEFT JOIN inventory_reservations ir
  ON ir.salvage_request_item_id = sri.id

GROUP BY
  r.id,
  r.request_number,
  r.status;