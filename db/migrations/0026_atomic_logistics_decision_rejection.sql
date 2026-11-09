BEGIN;

CREATE OR REPLACE FUNCTION reject_logistics_decision(
  p_decision_id UUID,
  p_user_id UUID
)
RETURNS SETOF logistics_decisions
LANGUAGE plpgsql
AS $$
DECLARE
  v_decision logistics_decisions%ROWTYPE;
BEGIN
  SELECT *
  INTO v_decision
  FROM logistics_decisions
  WHERE id = p_decision_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'LOGISTICS_DECISION_NOT_FOUND'
      USING ERRCODE = 'P0001';
  END IF;

  IF v_decision.decision_source <> 'system'
     OR v_decision.decision_status <> 'pending' THEN
    RAISE EXCEPTION 'LOGISTICS_DECISION_NOT_AVAILABLE'
      USING ERRCODE = 'P0001';
  END IF;

  UPDATE logistics_decisions
  SET
    decision_status = 'rejected',
    decided_by = p_user_id
  WHERE id = p_decision_id;

  INSERT INTO audit_logs (
    user_id,
    action,
    entity,
    entity_id,
    meta
  )
  VALUES (
    p_user_id,
    'trip:update',
    'logistics_decision',
    v_decision.id,
    jsonb_build_object(
      'source', 'logistics_decision',
      'decision_id', v_decision.id,
      'shipment_id', v_decision.shipment_id,
      'transfer_request_id', v_decision.transfer_request_id,
      'decision_type', v_decision.decision_type,
      'decision_status', 'rejected'
    )
  );

  RETURN QUERY
  SELECT *
  FROM logistics_decisions
  WHERE id = p_decision_id;
END;
$$;

COMMIT;