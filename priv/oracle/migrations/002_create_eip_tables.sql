-- Migration 002: Create EIP Tables
-- Purpose: Create staging, integration, and audit tables for EIP patterns
-- Author: GprintEx Team
-- Date: 2026-01-27

-- =============================================================================
-- ETL STAGING TABLES
-- =============================================================================

-- ETL session tracking
CREATE TABLE etl_sessions (
    session_id VARCHAR2(100) PRIMARY KEY,
    source_system VARCHAR2(100) NOT NULL,
    entity_type VARCHAR2(50) NOT NULL,
    status VARCHAR2(20) DEFAULT 'ACTIVE' NOT NULL,
    record_count NUMBER DEFAULT 0,
    success_count NUMBER DEFAULT 0,
    error_count NUMBER DEFAULT 0,
    started_at TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    completed_at TIMESTAMP,
    started_by VARCHAR2(100),
    metadata CLOB,
    CONSTRAINT chk_etl_session_status CHECK (status IN ('ACTIVE', 'PROCESSING', 'COMPLETED', 'FAILED', 'ROLLED_BACK'))
);

CREATE INDEX idx_etl_sessions_status ON etl_sessions(status);
CREATE INDEX idx_etl_sessions_source ON etl_sessions(source_system, entity_type);
CREATE INDEX idx_etl_sessions_started ON etl_sessions(started_at);

-- Add comments
COMMENT ON TABLE etl_sessions IS 'Tracks ETL session lifecycle and metadata';
COMMENT ON COLUMN etl_sessions.session_id IS 'Unique session identifier (UUID format)';
COMMENT ON COLUMN etl_sessions.source_system IS 'Origin system of the data (e.g., LEGACY_CRM, SAP)';
COMMENT ON COLUMN etl_sessions.entity_type IS 'Type of entity being processed (CONTRACT, CUSTOMER, etc.)';

-- Generic staging table for incoming data
CREATE TABLE etl_staging (
    session_id VARCHAR2(100) NOT NULL,
    seq_num NUMBER NOT NULL,
    entity_type VARCHAR2(50) NOT NULL,
    source_system VARCHAR2(100),
    raw_data CLOB,
    transformed_data CLOB,
    status VARCHAR2(20) DEFAULT 'PENDING' NOT NULL,
    error_message VARCHAR2(4000),
    created_at TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    processed_at TIMESTAMP,
    CONSTRAINT pk_etl_staging PRIMARY KEY (session_id, seq_num),
    CONSTRAINT fk_etl_staging_session FOREIGN KEY (session_id) 
        REFERENCES etl_sessions(session_id) ON DELETE CASCADE,
    CONSTRAINT chk_etl_staging_status CHECK (status IN ('PENDING', 'TRANSFORMED', 'VALIDATED', 'LOADED', 'FAILED', 'SKIPPED'))
);

CREATE INDEX idx_etl_staging_status ON etl_staging(status);
CREATE INDEX idx_etl_staging_entity ON etl_staging(entity_type);

-- Sequence for generating staging record seq_num (avoids race conditions)
CREATE SEQUENCE etl_staging_seq START WITH 1 INCREMENT BY 1 NOCACHE;

COMMENT ON TABLE etl_staging IS 'Temporary storage for data during ETL processing';
COMMENT ON COLUMN etl_staging.raw_data IS 'Original data as received (JSON/XML)';
COMMENT ON COLUMN etl_staging.transformed_data IS 'Data after transformation rules applied';

-- =============================================================================
-- INTEGRATION TABLES
-- =============================================================================

-- Message routing log
CREATE TABLE integration_messages (
    message_id VARCHAR2(100) PRIMARY KEY,
    correlation_id VARCHAR2(100),
    message_type VARCHAR2(50) NOT NULL,
    source_system VARCHAR2(100),
    routing_key VARCHAR2(200),
    destination VARCHAR2(200),
    payload CLOB,
    status VARCHAR2(20) DEFAULT 'PENDING' NOT NULL,
    created_at TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    processed_at TIMESTAMP,
    retry_count NUMBER DEFAULT 0,
    max_retries NUMBER DEFAULT 3,
    next_retry_at TIMESTAMP,
    error_message VARCHAR2(4000),
    CONSTRAINT chk_msg_status CHECK (status IN ('PENDING', 'PROCESSING', 'COMPLETED', 'FAILED', 'DEAD_LETTER'))
);

CREATE INDEX idx_integ_msg_correlation ON integration_messages(correlation_id);
CREATE INDEX idx_integ_msg_status ON integration_messages(status);
CREATE INDEX idx_integ_msg_type ON integration_messages(message_type);
CREATE INDEX idx_integ_msg_created ON integration_messages(created_at);
-- Function-based index: only indexes next_retry_at when status = 'PENDING'
CREATE INDEX idx_integ_msg_retry ON integration_messages(
    CASE WHEN status = 'PENDING' THEN next_retry_at ELSE NULL END
);

COMMENT ON TABLE integration_messages IS 'EIP message routing and tracking';
COMMENT ON COLUMN integration_messages.correlation_id IS 'Groups related messages for aggregation';
COMMENT ON COLUMN integration_messages.routing_key IS 'Key used for content-based routing';

-- Message deduplication
CREATE TABLE message_dedup (
    message_id VARCHAR2(100) PRIMARY KEY,
    message_hash VARCHAR2(64),
    first_seen TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    last_seen TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    process_count NUMBER DEFAULT 1,
    tenant_id VARCHAR2(50),
    message_type VARCHAR2(50)
);

CREATE INDEX idx_msg_dedup_hash ON message_dedup(message_hash);
CREATE INDEX idx_msg_dedup_first_seen ON message_dedup(first_seen);
CREATE INDEX idx_msg_dedup_tenant ON message_dedup(tenant_id);

COMMENT ON TABLE message_dedup IS 'Prevents duplicate message processing within time window';
COMMENT ON COLUMN message_dedup.message_hash IS 'SHA-256 hash of message content for duplicate detection';

-- Message aggregation tracking
CREATE TABLE message_aggregation (
    correlation_id VARCHAR2(100) NOT NULL,
    aggregation_key VARCHAR2(200) NOT NULL,
    expected_count NUMBER,
    current_count NUMBER DEFAULT 0,
    status VARCHAR2(20) DEFAULT 'PENDING' NOT NULL,
    started_at TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    timeout_at TIMESTAMP,
    completed_at TIMESTAMP,
    aggregated_result CLOB,
    CONSTRAINT pk_msg_aggregation PRIMARY KEY (correlation_id, aggregation_key),
    CONSTRAINT chk_agg_status CHECK (status IN ('PENDING', 'COMPLETE', 'TIMEOUT', 'CANCELLED'))
);

-- Function-based index: only indexes timeout_at when status = 'PENDING'
CREATE INDEX idx_msg_agg_timeout ON message_aggregation(
    CASE WHEN status = 'PENDING' THEN timeout_at ELSE NULL END
);
CREATE INDEX idx_msg_agg_status ON message_aggregation(status);

COMMENT ON TABLE message_aggregation IS 'Tracks message aggregation state for Aggregator pattern';

-- =============================================================================
-- AUDIT TABLES
-- =============================================================================

-- Transformation audit trail
CREATE TABLE transform_audit (
    audit_id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    session_id VARCHAR2(100),
    entity_type VARCHAR2(50) NOT NULL,
    entity_id VARCHAR2(100),
    tenant_id VARCHAR2(50),
    transform_type VARCHAR2(50) NOT NULL,
    transform_rule VARCHAR2(200),
    before_value CLOB,
    after_value CLOB,
    transform_timestamp TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    transformed_by VARCHAR2(100),
    CONSTRAINT fk_transform_audit_session FOREIGN KEY (session_id)
        REFERENCES etl_sessions(session_id) ON DELETE SET NULL
);

CREATE INDEX idx_transform_audit_session ON transform_audit(session_id);
CREATE INDEX idx_transform_audit_entity ON transform_audit(entity_type, entity_id);
CREATE INDEX idx_transform_audit_tenant ON transform_audit(tenant_id);
CREATE INDEX idx_transform_audit_time ON transform_audit(transform_timestamp);

COMMENT ON TABLE transform_audit IS 'Complete audit trail of all data transformations';
COMMENT ON COLUMN transform_audit.before_value IS 'Data state before transformation (JSON)';
COMMENT ON COLUMN transform_audit.after_value IS 'Data state after transformation (JSON)';

-- Data quality issues log
CREATE TABLE data_quality_issues (
    issue_id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    session_id VARCHAR2(100),
    entity_type VARCHAR2(50) NOT NULL,
    entity_id VARCHAR2(100),
    tenant_id VARCHAR2(50),
    severity VARCHAR2(20) NOT NULL,
    issue_type VARCHAR2(50) NOT NULL,
    field_name VARCHAR2(100),
    issue_description VARCHAR2(4000),
    original_value VARCHAR2(4000),
    suggested_value VARCHAR2(4000),
    resolution_status VARCHAR2(20) DEFAULT 'OPEN',
    resolved_at TIMESTAMP,
    resolved_by VARCHAR2(100),
    created_at TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT chk_dq_severity CHECK (severity IN ('INFO', 'WARNING', 'ERROR', 'CRITICAL')),
    CONSTRAINT chk_dq_resolution CHECK (resolution_status IN ('OPEN', 'FIXED', 'IGNORED', 'DEFERRED'))
);

CREATE INDEX idx_dq_issues_session ON data_quality_issues(session_id);
CREATE INDEX idx_dq_issues_severity ON data_quality_issues(severity);
CREATE INDEX idx_dq_issues_status ON data_quality_issues(resolution_status);

COMMENT ON TABLE data_quality_issues IS 'Tracks data quality problems discovered during ETL';

-- =============================================================================
-- CONTRACT STATUS HISTORY (extends existing contracts)
-- =============================================================================

CREATE TABLE contract_status_history (
    history_id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id VARCHAR2(50) NOT NULL,
    contract_id NUMBER NOT NULL,
    previous_status VARCHAR2(20),
    new_status VARCHAR2(20) NOT NULL,
    changed_at TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    changed_by VARCHAR2(100) NOT NULL,
    change_reason VARCHAR2(500),
    metadata CLOB
);

CREATE INDEX idx_contract_status_hist_contract ON contract_status_history(tenant_id, contract_id);
CREATE INDEX idx_contract_status_hist_time ON contract_status_history(changed_at);

COMMENT ON TABLE contract_status_history IS 'Audit trail for contract state machine transitions';

-- =============================================================================
-- ROUTING RULES CONFIGURATION
-- =============================================================================

CREATE TABLE routing_rules (
    rule_id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rule_name VARCHAR2(100) NOT NULL UNIQUE,
    rule_set VARCHAR2(50) NOT NULL,
    priority NUMBER DEFAULT 100,
    message_type VARCHAR2(50),
    condition_expression CLOB NOT NULL,
    destination VARCHAR2(200) NOT NULL,
    transform_template VARCHAR2(200),
    active NUMBER(1) DEFAULT 1,
    created_at TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at TIMESTAMP,
    created_by VARCHAR2(100),
    updated_by VARCHAR2(100)
);

CREATE INDEX idx_routing_rules_set ON routing_rules(rule_set, priority);
CREATE INDEX idx_routing_rules_type ON routing_rules(message_type);
CREATE INDEX idx_routing_rules_active ON routing_rules(active);

COMMENT ON TABLE routing_rules IS 'Configuration for content-based routing rules';
COMMENT ON COLUMN routing_rules.condition_expression IS 'JSON path or SQL expression for routing decision';
COMMENT ON COLUMN routing_rules.destination IS 'Target channel or handler for matched messages';

-- =============================================================================
-- CLEANUP JOBS TRACKING
-- =============================================================================

CREATE TABLE cleanup_jobs (
    job_id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    job_name VARCHAR2(100) NOT NULL,
    job_type VARCHAR2(50) NOT NULL,
    target_table VARCHAR2(100) NOT NULL,
    retention_days NUMBER DEFAULT 30,
    last_run_at TIMESTAMP,
    last_run_status VARCHAR2(20),
    records_deleted NUMBER DEFAULT 0,
    next_run_at TIMESTAMP,
    enabled NUMBER(1) DEFAULT 1,
    created_at TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL
);

COMMENT ON TABLE cleanup_jobs IS 'Tracks scheduled cleanup jobs for EIP tables';

-- Initial cleanup job entries
INSERT INTO cleanup_jobs (job_name, job_type, target_table, retention_days, enabled)
VALUES ('Clean ETL Staging', 'PURGE', 'etl_staging', 7, 1);

INSERT INTO cleanup_jobs (job_name, job_type, target_table, retention_days, enabled)
VALUES ('Clean Message Dedup', 'PURGE', 'message_dedup', 1, 1);

INSERT INTO cleanup_jobs (job_name, job_type, target_table, retention_days, enabled)
VALUES ('Archive Completed Sessions', 'ARCHIVE', 'etl_sessions', 30, 1);

INSERT INTO cleanup_jobs (job_name, job_type, target_table, retention_days, enabled)
VALUES ('Clean Integration Messages', 'PURGE', 'integration_messages', 90, 1);

COMMIT;

-- End of migration 002
