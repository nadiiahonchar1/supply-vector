-- =========================================================
-- 1. EXPANSION OF SALVAGE REQUEST STATUSES
-- =========================================================

ALTER TABLE salvage_requests
  DROP CONSTRAINT IF EXISTS salvage_requests_status_check;

ALTER TABLE salvage_requests
  ADD CONSTRAINT salvage_requests_status_check
  CHECK (
    status IN (
      'pending',
      'approved',
      'in_progress',
      'fulfilled',
      'partially_fulfilled',
      'rejected',
      'cancelled'
    )
  );


-- =========================================================
-- 2. RECORDING THE BASIS FOR TERMINATION
-- =========================================================

CREATE TABLE salvage_request_completions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  salvage_request_id UUID NOT NULL UNIQUE
    REFERENCES salvage_requests(id),

  completion_type TEXT NOT NULL,

  completed_by UUID NOT NULL
    REFERENCES users(id),

  comment TEXT,

  completed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT salvage_completion_type_check
    CHECK (
      completion_type IN (
        'fulfilled',
        'partially_fulfilled'
      )
    ),

  CONSTRAINT salvage_completion_comment_check
    CHECK (
      comment IS NULL OR LENGTH(comment) <= 2000
    )
);


-- =========================================================
-- 3. VERIFICATION OF THE COMPLETENESS OF PHYSICAL EXECUTION
-- =========================================================

CREATE OR REPLACE FUNCTION assert_salvage_request_resolved(
  p_request_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  v_total INTEGER;
  v_received INTEGER;
  v_returned INTEGER;
  v_lost INTEGER;
  v_written_off INTEGER;
  v_unresolved INTEGER;
BEGIN
  SELECT
    COALESCE(SUM(sri.approved_quantity), 0)
  INTO v_total
  FROM salvage_request_items sri
  WHERE sri.salvage_request_id = p_request_id;

  SELECT
    COALESCE(
      SUM(quantity) FILTER (
        WHERE event_type = 'received'
      ),
      0
    ),
    COALESCE(
      SUM(quantity) FILTER (
        WHERE event_type = 'returned'
      ),
      0
    ),
    COALESCE(
      SUM(quantity) FILTER (
        WHERE event_type = 'lost'
      ),
      0
    ),
    COALESCE(
      SUM(quantity) FILTER (
        WHERE event_type = 'written_off'
      ),
      0
    )
  INTO
    v_received,
    v_returned,
    v_lost,
    v_written_off
  FROM salvage_item_execution_events e
  JOIN salvage_request_items sri
    ON sri.id = e.salvage_request_item_id
  WHERE sri.salvage_request_id = p_request_id;

  v_unresolved :=
    v_total
    - v_received
    - v_returned
    - v_lost
    - v_written_off;

  IF v_unresolved > 0 THEN
    RAISE EXCEPTION
      'Salvage-заявка має невирішений залишок: %',
      v_unresolved;
  END IF;

  IF v_unresolved < 0 THEN
    RAISE EXCEPTION
      'Сумарний обсяг операцій перевищує погоджену кількість';
  END IF;

  IF v_total = 0 THEN
    RAISE EXCEPTION
      'Неможливо завершити заявку без погоджених позицій';
  END IF;

  IF v_received = v_total THEN
    RETURN 'fulfilled';
  END IF;

  RETURN 'partially_fulfilled';
END;
$$;


-- =========================================================
-- 4. ATOMIC COMPLETION OF A REQUEST
-- =========================================================

CREATE OR REPLACE FUNCTION complete_salvage_request(
  p_request_id UUID,
  p_user_id UUID,
  p_comment TEXT DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  v_status TEXT;
  v_completion_type TEXT;
BEGIN
  SELECT status
  INTO v_status
  FROM salvage_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Salvage-заявку не знайдено';
  END IF;

  IF v_status NOT IN ('approved', 'in_progress') THEN
    RAISE EXCEPTION
      'Заявка не перебуває у стані, що дозволяє завершення';
  END IF;

  v_completion_type :=
    assert_salvage_request_resolved(p_request_id);

  INSERT INTO salvage_request_completions (
    salvage_request_id,
    completion_type,
    completed_by,
    comment
  )
  VALUES (
    p_request_id,
    v_completion_type,
    p_user_id,
    p_comment
  );

  UPDATE salvage_requests
  SET
    status = v_completion_type,
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
    v_status,
    v_completion_type,
    p_user_id,
    COALESCE(
      p_comment,
      'Завершення після вирішення всього погодженого обсягу'
    )
  );

  RETURN v_completion_type;
END;
$$;


-- =========================================================
-- 5. PROHIBITION ON MODIFYING A COMPLETED APPLICATION
-- =========================================================

CREATE OR REPLACE FUNCTION guard_completed_salvage_request()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.status IN (
    'fulfilled',
    'partially_fulfilled',
    'rejected',
    'cancelled'
  ) AND NEW.status IS DISTINCT FROM OLD.status THEN
    RAISE EXCEPTION
      'Завершену salvage-заявку не можна відкрити повторно';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER completed_salvage_request_guard
BEFORE UPDATE OF status
ON salvage_requests
FOR EACH ROW
EXECUTE FUNCTION guard_completed_salvage_request();


-- =========================================================
-- 6. FINAL REVIEW OF APPLICATIONS
-- =========================================================

CREATE OR REPLACE VIEW v_salvage_request_completion AS
SELECT
  r.id AS salvage_request_id,
  r.request_number,
  r.status,

  COALESCE(SUM(sri.approved_quantity), 0)
    AS approved_quantity,

  COALESCE(SUM(events.received_quantity), 0)
    AS received_quantity,

  COALESCE(SUM(events.returned_quantity), 0)
    AS returned_quantity,

  COALESCE(SUM(events.lost_quantity), 0)
    AS lost_quantity,

  COALESCE(SUM(events.written_off_quantity), 0)
    AS written_off_quantity,

  COALESCE(SUM(sri.approved_quantity), 0)
  -
  COALESCE(SUM(events.received_quantity), 0)
  -
  COALESCE(SUM(events.returned_quantity), 0)
  -
  COALESCE(SUM(events.lost_quantity), 0)
  -
  COALESCE(SUM(events.written_off_quantity), 0)
    AS unresolved_quantity,

  c.completion_type,
  c.completed_at

FROM salvage_requests r

LEFT JOIN salvage_request_items sri
  ON sri.salvage_request_id = r.id

LEFT JOIN LATERAL (
  SELECT
    SUM(quantity) FILTER (
      WHERE event_type = 'received'
    ) AS received_quantity,

    SUM(quantity) FILTER (
      WHERE event_type = 'returned'
    ) AS returned_quantity,

    SUM(quantity) FILTER (
      WHERE event_type = 'lost'
    ) AS lost_quantity,

    SUM(quantity) FILTER (
      WHERE event_type = 'written_off'
    ) AS written_off_quantity

  FROM salvage_item_execution_events e
  WHERE e.salvage_request_item_id = sri.id
) events ON TRUE

LEFT JOIN salvage_request_completions c
  ON c.salvage_request_id = r.id

GROUP BY
  r.id,
  r.request_number,
  r.status,
  c.completion_type,
  c.completed_at;