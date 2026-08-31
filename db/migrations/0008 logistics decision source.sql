ALTER TABLE logistics_decisions
  ADD COLUMN decision_source TEXT NOT NULL DEFAULT 'system'
    CHECK (decision_source IN ('system', 'manual')),
  ADD COLUMN decided_by UUID REFERENCES users(id);
 
ALTER TABLE logistics_decisions
  ADD CONSTRAINT chk_logistics_decisions_decided_by
    CHECK (
      (decision_source = 'manual' AND decided_by IS NOT NULL)
      OR (decision_source = 'system' AND decided_by IS NULL)
    );
 
CREATE INDEX idx_logistics_decisions_decided_by ON logistics_decisions(decided_by);
 