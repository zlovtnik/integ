-- ETL_PKG - ETL Operations Package
-- Purpose: Staging, transformation, and loading operations for ETL pipelines
-- Author: GprintEx Team
-- Date: 2026-01-27

CREATE OR REPLACE PACKAGE etl_pkg AS
    -- ==========================================================================
    -- CONSTANTS
    -- ==========================================================================
    
    -- Session status
    c_session_active     CONSTANT VARCHAR2(20) := 'ACTIVE';
    c_session_processing CONSTANT VARCHAR2(20) := 'PROCESSING';
    c_session_completed  CONSTANT VARCHAR2(20) := 'COMPLETED';
    c_session_failed     CONSTANT VARCHAR2(20) := 'FAILED';
    c_session_rolled_back CONSTANT VARCHAR2(20) := 'ROLLED_BACK';
    
    -- Record status
    c_record_pending     CONSTANT VARCHAR2(20) := 'PENDING';
    c_record_transformed CONSTANT VARCHAR2(20) := 'TRANSFORMED';
    c_record_validated   CONSTANT VARCHAR2(20) := 'VALIDATED';
    c_record_loaded      CONSTANT VARCHAR2(20) := 'LOADED';
    c_record_failed      CONSTANT VARCHAR2(20) := 'FAILED';
    c_record_skipped     CONSTANT VARCHAR2(20) := 'SKIPPED';
    
    -- ==========================================================================
    -- EXCEPTIONS
    -- ==========================================================================
    
    e_session_not_found EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_session_not_found, -20010);
    
    e_session_not_active EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_session_not_active, -20011);
    
    e_invalid_format EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_invalid_format, -20012);
    
    e_unsupported_target EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_unsupported_target, -20013);
    
    -- ==========================================================================
    -- SESSION MANAGEMENT
    -- ==========================================================================
    
    -- Create a new staging session
    PROCEDURE create_staging_session(
        p_session_id OUT VARCHAR2,
        p_source_system IN VARCHAR2,
        p_entity_type IN VARCHAR2,
        p_user IN VARCHAR2 DEFAULT NULL
    );
    
    -- Get session status
    FUNCTION get_session_status(
        p_session_id IN VARCHAR2
    ) RETURN VARCHAR2;
    
    -- Get session metadata
    FUNCTION get_session_info(
        p_session_id IN VARCHAR2
    ) RETURN SYS_REFCURSOR;
    
    -- ==========================================================================
    -- DATA LOADING (into staging)
    -- ==========================================================================
    
    -- Load JSON data to staging
    PROCEDURE load_to_staging(
        p_session_id IN VARCHAR2,
        p_data IN CLOB,
        p_format IN VARCHAR2 DEFAULT 'JSON'
    );
    
    -- Load single record to staging
    PROCEDURE load_record_to_staging(
        p_session_id IN VARCHAR2,
        p_raw_data IN CLOB,
        p_seq_num OUT NUMBER
    );
    
    -- Batch load records
    PROCEDURE batch_load_to_staging(
        p_session_id IN VARCHAR2,
        p_records IN etl_staging_tab
    );
    
    -- ==========================================================================
    -- TRANSFORMATION
    -- ==========================================================================
    
    -- Transform staged contracts using rules
    PROCEDURE transform_contracts(
        p_session_id IN VARCHAR2,
        p_transformation_rules IN CLOB,
        p_results OUT transform_metadata_t
    );
    
    -- Transform staged customers
    PROCEDURE transform_customers(
        p_session_id IN VARCHAR2,
        p_transformation_rules IN CLOB,
        p_results OUT transform_metadata_t
    );
    
    -- Apply generic business rules
    PROCEDURE apply_business_rules(
        p_session_id IN VARCHAR2,
        p_rule_set IN VARCHAR2
    );
    
    -- ==========================================================================
    -- VALIDATION
    -- ==========================================================================
    
    -- Validate staging data (pipelined for streaming results - no DML)
    FUNCTION validate_staging_data(
        p_session_id IN VARCHAR2
    ) RETURN validation_results_tab PIPELINED;
    
    -- Apply validation results to staging records (performs DML)
    PROCEDURE apply_validation_results(
        p_session_id IN VARCHAR2
    );
    
    -- Get validation summary
    FUNCTION get_validation_summary(
        p_session_id IN VARCHAR2
    ) RETURN SYS_REFCURSOR;
    
    -- ==========================================================================
    -- LOADING (from staging to target)
    -- ==========================================================================
    
    -- Promote validated data from staging to target table
    PROCEDURE promote_from_staging(
        p_session_id IN VARCHAR2,
        p_target_table IN VARCHAR2,
        p_user IN VARCHAR2,
        p_results OUT transform_metadata_t
    );
    
    -- Promote contracts from staging
    PROCEDURE promote_contracts(
        p_session_id IN VARCHAR2,
        p_user IN VARCHAR2,
        p_results OUT transform_metadata_t
    );
    
    -- Promote customers from staging
    PROCEDURE promote_customers(
        p_session_id IN VARCHAR2,
        p_user IN VARCHAR2,
        p_results OUT transform_metadata_t
    );
    
    -- ==========================================================================
    -- SESSION LIFECYCLE
    -- ==========================================================================
    
    -- Complete session successfully
    PROCEDURE complete_session(
        p_session_id IN VARCHAR2
    );
    
    -- Fail session
    PROCEDURE fail_session(
        p_session_id IN VARCHAR2,
        p_error_message IN VARCHAR2
    );
    
    -- Rollback session (remove all staged data)
    PROCEDURE rollback_session(
        p_session_id IN VARCHAR2
    );
    
    -- ==========================================================================
    -- AUDIT & MONITORING
    -- ==========================================================================
    
    -- Get session audit trail
    FUNCTION get_session_audit_trail(
        p_session_id IN VARCHAR2
    ) RETURN SYS_REFCURSOR;
    
    -- Get active sessions
    FUNCTION get_active_sessions RETURN SYS_REFCURSOR;
    
    -- Cleanup old sessions
    PROCEDURE cleanup_old_sessions(
        p_retention_days IN NUMBER DEFAULT 7,
        p_deleted_count OUT NUMBER
    );
    
END etl_pkg;
/

CREATE OR REPLACE PACKAGE BODY etl_pkg AS
    
    -- ==========================================================================
    -- PRIVATE HELPERS
    -- ==========================================================================
    
    -- Generate unique session ID
    FUNCTION generate_session_id RETURN VARCHAR2 IS
    BEGIN
        RETURN SYS_GUID();
    END generate_session_id;
    
    -- Check if session is active
    PROCEDURE ensure_session_active(p_session_id IN VARCHAR2) IS
        v_status VARCHAR2(20);
    BEGIN
        SELECT status INTO v_status
        FROM etl_sessions
        WHERE session_id = p_session_id;
        
        IF v_status NOT IN (c_session_active, c_session_processing) THEN
            RAISE_APPLICATION_ERROR(-20011, 'Session is not active: ' || p_session_id);
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20010, 'Session not found: ' || p_session_id);
    END ensure_session_active;
    
    -- Update session counts
    PROCEDURE update_session_counts(p_session_id IN VARCHAR2) IS
    BEGIN
        UPDATE etl_sessions SET
            record_count = (SELECT COUNT(*) FROM etl_staging WHERE session_id = p_session_id),
            success_count = (SELECT COUNT(*) FROM etl_staging WHERE session_id = p_session_id AND status IN (c_record_transformed, c_record_validated, c_record_loaded)),
            error_count = (SELECT COUNT(*) FROM etl_staging WHERE session_id = p_session_id AND status = c_record_failed)
        WHERE session_id = p_session_id;
    END update_session_counts;
    
    -- Record transformation audit
    PROCEDURE record_transform_audit(
        p_session_id IN VARCHAR2,
        p_entity_type IN VARCHAR2,
        p_entity_id IN VARCHAR2,
        p_tenant_id IN VARCHAR2,
        p_transform_type IN VARCHAR2,
        p_transform_rule IN VARCHAR2,
        p_before_value IN CLOB,
        p_after_value IN CLOB,
        p_user IN VARCHAR2
    ) IS
    BEGIN
        INSERT INTO transform_audit (
            session_id, entity_type, entity_id, tenant_id,
            transform_type, transform_rule, before_value, after_value,
            transform_timestamp, transformed_by
        ) VALUES (
            p_session_id, p_entity_type, p_entity_id, p_tenant_id,
            p_transform_type, p_transform_rule, p_before_value, p_after_value,
            SYSTIMESTAMP, p_user
        );
    END record_transform_audit;
    
    -- ==========================================================================
    -- SESSION MANAGEMENT
    -- ==========================================================================
    
    PROCEDURE create_staging_session(
        p_session_id OUT VARCHAR2,
        p_source_system IN VARCHAR2,
        p_entity_type IN VARCHAR2,
        p_user IN VARCHAR2 DEFAULT NULL
    ) IS
    BEGIN
        p_session_id := generate_session_id();
        
        INSERT INTO etl_sessions (
            session_id, source_system, entity_type, status,
            started_at, started_by
        ) VALUES (
            p_session_id, p_source_system, p_entity_type, c_session_active,
            SYSTIMESTAMP, p_user
        );
        
        COMMIT;
    END create_staging_session;
    
    FUNCTION get_session_status(
        p_session_id IN VARCHAR2
    ) RETURN VARCHAR2 IS
        v_status VARCHAR2(20);
    BEGIN
        SELECT status INTO v_status
        FROM etl_sessions
        WHERE session_id = p_session_id;
        
        RETURN v_status;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20010, 'Session not found: ' || p_session_id);
    END get_session_status;
    
    FUNCTION get_session_info(
        p_session_id IN VARCHAR2
    ) RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT s.*,
                (SELECT COUNT(*) FROM etl_staging WHERE session_id = s.session_id AND status = c_record_pending) as pending_count,
                (SELECT COUNT(*) FROM etl_staging WHERE session_id = s.session_id AND status = c_record_transformed) as transformed_count,
                (SELECT COUNT(*) FROM etl_staging WHERE session_id = s.session_id AND status = c_record_validated) as validated_count,
                (SELECT COUNT(*) FROM etl_staging WHERE session_id = s.session_id AND status = c_record_loaded) as loaded_count,
                (SELECT COUNT(*) FROM etl_staging WHERE session_id = s.session_id AND status = c_record_failed) as failed_count
            FROM etl_sessions s
            WHERE s.session_id = p_session_id;
            
        RETURN v_cursor;
    END get_session_info;
    
    -- ==========================================================================
    -- DATA LOADING
    -- ==========================================================================
    
    PROCEDURE load_to_staging(
        p_session_id IN VARCHAR2,
        p_data IN CLOB,
        p_format IN VARCHAR2 DEFAULT 'JSON'
    ) IS
        v_entity_type VARCHAR2(50);
        v_source_system VARCHAR2(100);
        v_seq_num NUMBER := 0;
    BEGIN
        ensure_session_active(p_session_id);
        
        -- Get session info
        SELECT entity_type, source_system INTO v_entity_type, v_source_system
        FROM etl_sessions
        WHERE session_id = p_session_id;
        
        IF p_format = 'JSON' THEN
            -- Parse JSON array and insert each record
            -- Note: For Oracle 12c+, we can use JSON_TABLE
            -- For compatibility, we're using a simplified approach
            FOR r IN (
                SELECT ROWNUM as rn, jt.*
                FROM JSON_TABLE(
                    p_data,
                    '$[*]' COLUMNS (
                        record_data CLOB FORMAT JSON PATH '$'
                    )
                ) jt
            ) LOOP
                v_seq_num := v_seq_num + 1;
                
                INSERT INTO etl_staging (
                    session_id, seq_num, entity_type, source_system,
                    raw_data, status, created_at
                ) VALUES (
                    p_session_id, v_seq_num, v_entity_type, v_source_system,
                    r.record_data, c_record_pending, SYSTIMESTAMP
                );
            END LOOP;
        ELSE
            RAISE_APPLICATION_ERROR(-20012, 'Unsupported format: ' || p_format);
        END IF;
        
        -- Update session status
        UPDATE etl_sessions SET
            status = c_session_processing,
            record_count = v_seq_num
        WHERE session_id = p_session_id;
        
        COMMIT;
    END load_to_staging;
    
    PROCEDURE load_record_to_staging(
        p_session_id IN VARCHAR2,
        p_raw_data IN CLOB,
        p_seq_num OUT NUMBER
    ) IS
        v_entity_type VARCHAR2(50);
        v_source_system VARCHAR2(100);
    BEGIN
        ensure_session_active(p_session_id);
        
        SELECT entity_type, source_system INTO v_entity_type, v_source_system
        FROM etl_sessions
        WHERE session_id = p_session_id;
        
        -- Use sequence for race-free seq_num assignment
        SELECT etl_staging_seq.NEXTVAL INTO p_seq_num FROM DUAL;
        
        INSERT INTO etl_staging (
            session_id, seq_num, entity_type, source_system,
            raw_data, status, created_at
        ) VALUES (
            p_session_id, p_seq_num, v_entity_type, v_source_system,
            p_raw_data, c_record_pending, SYSTIMESTAMP
        );
        
        update_session_counts(p_session_id);
        COMMIT;
    END load_record_to_staging;
    
    PROCEDURE batch_load_to_staging(
        p_session_id IN VARCHAR2,
        p_records IN etl_staging_tab
    ) IS
    BEGIN
        ensure_session_active(p_session_id);
        
        FORALL i IN 1..p_records.COUNT
            INSERT INTO etl_staging VALUES p_records(i);
            
        update_session_counts(p_session_id);
        COMMIT;
    END batch_load_to_staging;
    
    -- ==========================================================================
    -- TRANSFORMATION
    -- ==========================================================================
    
    PROCEDURE transform_contracts(
        p_session_id IN VARCHAR2,
        p_transformation_rules IN CLOB,
        p_results OUT transform_metadata_t
    ) IS
        v_transformed_data CLOB;
        v_source_system VARCHAR2(100);
    BEGIN
        ensure_session_active(p_session_id);
        
        p_results := transform_metadata_t(p_session_id);
        
        SELECT source_system INTO v_source_system
        FROM etl_sessions
        WHERE session_id = p_session_id;
        
        p_results.source_system := v_source_system;
        
        FOR r IN (
            SELECT session_id, seq_num, raw_data
            FROM etl_staging
            WHERE session_id = p_session_id
              AND entity_type = 'CONTRACT'
              AND status = c_record_pending
        ) LOOP
            BEGIN
                p_results.record_count := p_results.record_count + 1;
                
                -- Apply transformation rules (simplified)
                -- In production, this would parse the rules JSON and apply them
                v_transformed_data := r.raw_data;
                
                -- Example transformation: ensure required fields
                -- This would be more sophisticated with actual JSON manipulation
                
                UPDATE etl_staging SET
                    transformed_data = v_transformed_data,
                    status = c_record_transformed,
                    processed_at = SYSTIMESTAMP
                WHERE session_id = r.session_id AND seq_num = r.seq_num;
                
                p_results.success_count := p_results.success_count + 1;
                
            EXCEPTION
                WHEN OTHERS THEN
                    UPDATE etl_staging SET
                        status = c_record_failed,
                        error_message = SQLERRM,
                        processed_at = SYSTIMESTAMP
                    WHERE session_id = r.session_id AND seq_num = r.seq_num;
                    
                    p_results.error_count := p_results.error_count + 1;
            END;
        END LOOP;
        
        p_results.transform_timestamp := SYSTIMESTAMP;
        update_session_counts(p_session_id);
        COMMIT;
    END transform_contracts;
    
    PROCEDURE transform_customers(
        p_session_id IN VARCHAR2,
        p_transformation_rules IN CLOB,
        p_results OUT transform_metadata_t
    ) IS
        v_transformed_data CLOB;
        v_source_system VARCHAR2(100);
    BEGIN
        ensure_session_active(p_session_id);
        
        p_results := transform_metadata_t(p_session_id);
        
        SELECT source_system INTO v_source_system
        FROM etl_sessions
        WHERE session_id = p_session_id;
        
        p_results.source_system := v_source_system;
        
        FOR r IN (
            SELECT session_id, seq_num, raw_data
            FROM etl_staging
            WHERE session_id = p_session_id
              AND entity_type = 'CUSTOMER'
              AND status = c_record_pending
        ) LOOP
            BEGIN
                p_results.record_count := p_results.record_count + 1;
                v_transformed_data := r.raw_data;
                
                UPDATE etl_staging SET
                    transformed_data = v_transformed_data,
                    status = c_record_transformed,
                    processed_at = SYSTIMESTAMP
                WHERE session_id = r.session_id AND seq_num = r.seq_num;
                
                p_results.success_count := p_results.success_count + 1;
                
            EXCEPTION
                WHEN OTHERS THEN
                    UPDATE etl_staging SET
                        status = c_record_failed,
                        error_message = SQLERRM,
                        processed_at = SYSTIMESTAMP
                    WHERE session_id = r.session_id AND seq_num = r.seq_num;
                    
                    p_results.error_count := p_results.error_count + 1;
            END;
        END LOOP;
        
        p_results.transform_timestamp := SYSTIMESTAMP;
        update_session_counts(p_session_id);
        COMMIT;
    END transform_customers;
    
    PROCEDURE apply_business_rules(
        p_session_id IN VARCHAR2,
        p_rule_set IN VARCHAR2
    ) IS
    BEGIN
        ensure_session_active(p_session_id);
        
        -- Apply business rules based on rule_set name
        -- This would look up rules from routing_rules table and apply them
        NULL; -- Placeholder for rule application logic
        
        COMMIT;
    END apply_business_rules;
    
    -- ==========================================================================
    -- VALIDATION
    -- ==========================================================================
    
    -- Pipelined function ONLY returns validation issues (no DML)
    FUNCTION validate_staging_data(
        p_session_id IN VARCHAR2
    ) RETURN validation_results_tab PIPELINED IS
        v_result validation_result_t;
        v_json_obj JSON_OBJECT_T;
        v_has_error BOOLEAN;
    BEGIN
        FOR r IN (
            SELECT session_id, seq_num, entity_type, transformed_data, status
            FROM etl_staging
            WHERE session_id = p_session_id
              AND status = c_record_transformed
        ) LOOP
            v_has_error := FALSE;
            BEGIN
                -- Parse and validate JSON data
                v_json_obj := JSON_OBJECT_T.parse(r.transformed_data);
                
                -- Entity-specific validation
                IF r.entity_type = 'CONTRACT' THEN
                    -- Validate required contract fields
                    IF NOT v_json_obj.has('tenant_id') THEN
                        v_result := validation_result_t(r.seq_num, 'MISSING_FIELD', 'tenant_id is required', 'seq_num=' || r.seq_num);
                        v_has_error := TRUE;
                        PIPE ROW(v_result);
                    END IF;
                    
                    IF NOT v_json_obj.has('contract_number') THEN
                        v_result := validation_result_t(r.seq_num, 'MISSING_FIELD', 'contract_number is required', 'seq_num=' || r.seq_num);
                        v_has_error := TRUE;
                        PIPE ROW(v_result);
                    END IF;
                    
                ELSIF r.entity_type = 'CUSTOMER' THEN
                    -- Validate required customer fields
                    IF NOT v_json_obj.has('tenant_id') THEN
                        v_result := validation_result_t(r.seq_num, 'MISSING_FIELD', 'tenant_id is required', 'seq_num=' || r.seq_num);
                        v_has_error := TRUE;
                        PIPE ROW(v_result);
                    END IF;
                    
                    IF NOT v_json_obj.has('customer_code') THEN
                        v_result := validation_result_t(r.seq_num, 'MISSING_FIELD', 'customer_code is required', 'seq_num=' || r.seq_num);
                        v_has_error := TRUE;
                        PIPE ROW(v_result);
                    END IF;
                END IF;
                
                -- Only pipe success if no errors for this record
                IF NOT v_has_error THEN
                    v_result := validation_result_t(r.seq_num, 'VALID', 'Record passed validation', NULL);
                    PIPE ROW(v_result);
                END IF;
                
            EXCEPTION
                WHEN OTHERS THEN
                    v_result := validation_result_t(r.seq_num, 'PARSE_ERROR', SQLERRM, 'seq_num=' || r.seq_num);
                    PIPE ROW(v_result);
            END;
        END LOOP;
        
        RETURN;
    END validate_staging_data;
    
    -- Separate procedure for applying validation results (handles DML)
    PROCEDURE apply_validation_results(
        p_session_id IN VARCHAR2
    ) IS
    BEGIN
        -- Collect validation results and update staging records
        FOR r IN (SELECT * FROM TABLE(validate_staging_data(p_session_id))) LOOP
            IF r.issue_type = 'VALID' THEN
                UPDATE etl_staging SET
                    status = c_record_validated,
                    processed_at = SYSTIMESTAMP
                WHERE session_id = p_session_id AND seq_num = r.record_id;
            ELSE
                UPDATE etl_staging SET
                    status = c_record_failed,
                    error_message = r.issue_type || ': ' || r.message,
                    processed_at = SYSTIMESTAMP
                WHERE session_id = p_session_id AND seq_num = r.record_id;
            END IF;
        END LOOP;
        
        update_session_counts(p_session_id);
        COMMIT;
    END apply_validation_results;
    
    FUNCTION get_validation_summary(
        p_session_id IN VARCHAR2
    ) RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT
                status,
                COUNT(*) as record_count,
                COUNT(error_message) as error_count
            FROM etl_staging
            WHERE session_id = p_session_id
            GROUP BY status
            ORDER BY status;
            
        RETURN v_cursor;
    END get_validation_summary;
    
    -- ==========================================================================
    -- LOADING (from staging to target)
    -- ==========================================================================
    
    PROCEDURE promote_from_staging(
        p_session_id IN VARCHAR2,
        p_target_table IN VARCHAR2,
        p_user IN VARCHAR2,
        p_results OUT transform_metadata_t
    ) IS
    BEGIN
        IF UPPER(p_target_table) = 'CONTRACTS' THEN
            promote_contracts(p_session_id, p_user, p_results);
        ELSIF UPPER(p_target_table) = 'CUSTOMERS' THEN
            promote_customers(p_session_id, p_user, p_results);
        ELSE
            RAISE_APPLICATION_ERROR(-20013, 'Unsupported target table: ' || p_target_table);
        END IF;
    END promote_from_staging;
    
    PROCEDURE promote_contracts(
        p_session_id IN VARCHAR2,
        p_user IN VARCHAR2,
        p_results OUT transform_metadata_t
    ) IS
        v_json_obj JSON_OBJECT_T;
        v_contract contract_t;
        v_contract_id NUMBER;
    BEGIN
        ensure_session_active(p_session_id);
        p_results := transform_metadata_t(p_session_id);
        
        FOR r IN (
            SELECT session_id, seq_num, transformed_data
            FROM etl_staging
            WHERE session_id = p_session_id
              AND entity_type = 'CONTRACT'
              AND status = c_record_validated
        ) LOOP
            BEGIN
                p_results.record_count := p_results.record_count + 1;
                
                -- Parse JSON to contract object
                v_json_obj := JSON_OBJECT_T.parse(r.transformed_data);
                
                v_contract := contract_t(
                    v_json_obj.get_String('tenant_id'),
                    v_json_obj.get_String('contract_number'),
                    v_json_obj.get_Number('customer_id'),
                    TO_DATE(v_json_obj.get_String('start_date'), 'YYYY-MM-DD')
                );
                
                -- Set optional fields
                IF v_json_obj.has('contract_type') THEN
                    v_contract.contract_type := v_json_obj.get_String('contract_type');
                END IF;
                
                IF v_json_obj.has('end_date') THEN
                    v_contract.end_date := TO_DATE(v_json_obj.get_String('end_date'), 'YYYY-MM-DD');
                END IF;
                
                IF v_json_obj.has('total_value') THEN
                    v_contract.total_value := v_json_obj.get_Number('total_value');
                END IF;
                
                IF v_json_obj.has('status') THEN
                    v_contract.status := v_json_obj.get_String('status');
                END IF;
                
                -- Insert via package
                v_contract_id := contract_pkg.insert_contract(v_contract, p_user);
                
                UPDATE etl_staging SET
                    status = c_record_loaded,
                    processed_at = SYSTIMESTAMP
                WHERE session_id = r.session_id AND seq_num = r.seq_num;
                
                p_results.success_count := p_results.success_count + 1;
                
            EXCEPTION
                WHEN OTHERS THEN
                    UPDATE etl_staging SET
                        status = c_record_failed,
                        error_message = SQLERRM,
                        processed_at = SYSTIMESTAMP
                    WHERE session_id = r.session_id AND seq_num = r.seq_num;
                    
                    p_results.error_count := p_results.error_count + 1;
            END;
        END LOOP;
        
        p_results.transform_timestamp := SYSTIMESTAMP;
        update_session_counts(p_session_id);
        COMMIT;
    END promote_contracts;
    
    PROCEDURE promote_customers(
        p_session_id IN VARCHAR2,
        p_user IN VARCHAR2,
        p_results OUT transform_metadata_t
    ) IS
        v_json_obj JSON_OBJECT_T;
        v_customer customer_t;
        v_customer_id NUMBER;
    BEGIN
        ensure_session_active(p_session_id);
        p_results := transform_metadata_t(p_session_id);
        
        FOR r IN (
            SELECT session_id, seq_num, transformed_data
            FROM etl_staging
            WHERE session_id = p_session_id
              AND entity_type = 'CUSTOMER'
              AND status = c_record_validated
        ) LOOP
            BEGIN
                p_results.record_count := p_results.record_count + 1;
                
                v_json_obj := JSON_OBJECT_T.parse(r.transformed_data);
                
                v_customer := customer_t(
                    v_json_obj.get_String('tenant_id'),
                    v_json_obj.get_String('customer_code'),
                    v_json_obj.get_String('name')
                );
                
                IF v_json_obj.has('customer_type') THEN
                    v_customer.customer_type := v_json_obj.get_String('customer_type');
                END IF;
                
                IF v_json_obj.has('email') THEN
                    v_customer.email := v_json_obj.get_String('email');
                END IF;
                
                IF v_json_obj.has('tax_id') THEN
                    v_customer.tax_id := v_json_obj.get_String('tax_id');
                END IF;
                
                v_customer_id := customer_pkg.insert_customer(v_customer, p_user);
                
                UPDATE etl_staging SET
                    status = c_record_loaded,
                    processed_at = SYSTIMESTAMP
                WHERE session_id = r.session_id AND seq_num = r.seq_num;
                
                p_results.success_count := p_results.success_count + 1;
                
            EXCEPTION
                WHEN OTHERS THEN
                    UPDATE etl_staging SET
                        status = c_record_failed,
                        error_message = SQLERRM,
                        processed_at = SYSTIMESTAMP
                    WHERE session_id = r.session_id AND seq_num = r.seq_num;
                    
                    p_results.error_count := p_results.error_count + 1;
            END;
        END LOOP;
        
        p_results.transform_timestamp := SYSTIMESTAMP;
        update_session_counts(p_session_id);
        COMMIT;
    END promote_customers;
    
    -- ==========================================================================
    -- SESSION LIFECYCLE
    -- ==========================================================================
    
    PROCEDURE complete_session(
        p_session_id IN VARCHAR2
    ) IS
    BEGIN
        UPDATE etl_sessions SET
            status = c_session_completed,
            completed_at = SYSTIMESTAMP
        WHERE session_id = p_session_id;
        
        update_session_counts(p_session_id);
        COMMIT;
    END complete_session;
    
    PROCEDURE fail_session(
        p_session_id IN VARCHAR2,
        p_error_message IN VARCHAR2
    ) IS
        v_metadata CLOB;
    BEGIN
        -- Use JSON_OBJECT for safe JSON construction (handles escaping)
        SELECT JSON_OBJECT('error' VALUE p_error_message)
        INTO v_metadata
        FROM DUAL;
        
        UPDATE etl_sessions SET
            status = c_session_failed,
            completed_at = SYSTIMESTAMP,
            metadata = v_metadata
        WHERE session_id = p_session_id;
        
        update_session_counts(p_session_id);
        COMMIT;
    END fail_session;
    
    PROCEDURE rollback_session(
        p_session_id IN VARCHAR2
    ) IS
    BEGIN
        -- Delete all staging data
        DELETE FROM etl_staging WHERE session_id = p_session_id;
        
        -- Update session status
        UPDATE etl_sessions SET
            status = c_session_rolled_back,
            completed_at = SYSTIMESTAMP,
            record_count = 0,
            success_count = 0,
            error_count = 0
        WHERE session_id = p_session_id;
        
        COMMIT;
    END rollback_session;
    
    -- ==========================================================================
    -- AUDIT & MONITORING
    -- ==========================================================================
    
    FUNCTION get_session_audit_trail(
        p_session_id IN VARCHAR2
    ) RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT *
            FROM transform_audit
            WHERE session_id = p_session_id
            ORDER BY transform_timestamp;
            
        RETURN v_cursor;
    END get_session_audit_trail;
    
    FUNCTION get_active_sessions RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT *
            FROM etl_sessions
            WHERE status IN (c_session_active, c_session_processing)
            ORDER BY started_at DESC;
            
        RETURN v_cursor;
    END get_active_sessions;
    
    PROCEDURE cleanup_old_sessions(
        p_retention_days IN NUMBER DEFAULT 7,
        p_deleted_count OUT NUMBER
    ) IS
        v_cutoff_date TIMESTAMP;
    BEGIN
        v_cutoff_date := SYSTIMESTAMP - INTERVAL '1' DAY * p_retention_days;
        
        -- Delete staging data first (FK constraint)
        DELETE FROM etl_staging
        WHERE session_id IN (
            SELECT session_id
            FROM etl_sessions
            WHERE status IN (c_session_completed, c_session_failed, c_session_rolled_back)
              AND completed_at < v_cutoff_date
        );
        
        -- Delete sessions
        DELETE FROM etl_sessions
        WHERE status IN (c_session_completed, c_session_failed, c_session_rolled_back)
          AND completed_at < v_cutoff_date;
        
        p_deleted_count := SQL%ROWCOUNT;
        COMMIT;
    END cleanup_old_sessions;
    
END etl_pkg;
/
