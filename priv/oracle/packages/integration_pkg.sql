-- INTEGRATION_PKG - Integration Patterns Package
-- Purpose: Message routing, transformation, aggregation, and deduplication
-- Author: GprintEx Team
-- Date: 2026-01-27

CREATE OR REPLACE PACKAGE integration_pkg AS
    -- ==========================================================================
    -- CONSTANTS
    -- ==========================================================================
    
    -- Message status
    c_msg_pending     CONSTANT VARCHAR2(20) := 'PENDING';
    c_msg_processing  CONSTANT VARCHAR2(20) := 'PROCESSING';
    c_msg_completed   CONSTANT VARCHAR2(20) := 'COMPLETED';
    c_msg_failed      CONSTANT VARCHAR2(20) := 'FAILED';
    c_msg_dead_letter CONSTANT VARCHAR2(20) := 'DEAD_LETTER';
    
    -- Aggregation status
    c_agg_pending   CONSTANT VARCHAR2(20) := 'PENDING';
    c_agg_complete  CONSTANT VARCHAR2(20) := 'COMPLETE';
    c_agg_timeout   CONSTANT VARCHAR2(20) := 'TIMEOUT';
    c_agg_cancelled CONSTANT VARCHAR2(20) := 'CANCELLED';
    
    -- Default values
    c_default_dedup_hours CONSTANT NUMBER := 24;
    c_default_max_retries CONSTANT NUMBER := 3;
    
    -- ==========================================================================
    -- EXCEPTIONS
    -- ==========================================================================
    
    e_duplicate_message EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_duplicate_message, -20020);
    
    e_routing_failed EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_routing_failed, -20021);
    
    e_aggregation_timeout EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_aggregation_timeout, -20022);
    
    -- ==========================================================================
    -- MESSAGE ROUTING
    -- ==========================================================================
    
    -- Route a message to appropriate destination
    PROCEDURE route_message(
        p_message_id IN VARCHAR2,
        p_message_type IN VARCHAR2,
        p_payload IN CLOB,
        p_routing_key IN VARCHAR2 DEFAULT NULL,
        p_correlation_id IN VARCHAR2 DEFAULT NULL,
        p_source_system IN VARCHAR2 DEFAULT NULL,
        p_destination OUT VARCHAR2
    );
    
    -- Content-based routing evaluation
    FUNCTION evaluate_routing_rules(
        p_content IN CLOB,
        p_rule_set IN VARCHAR2
    ) RETURN VARCHAR2;
    
    -- Get routing destination for message type
    FUNCTION get_destination(
        p_message_type IN VARCHAR2,
        p_routing_key IN VARCHAR2 DEFAULT NULL
    ) RETURN VARCHAR2;
    
    -- ==========================================================================
    -- MESSAGE TRANSFORMATION
    -- ==========================================================================
    
    -- Transform message between formats
    FUNCTION transform_message(
        p_source_format IN VARCHAR2,
        p_target_format IN VARCHAR2,
        p_message IN CLOB,
        p_mapping_template IN VARCHAR2 DEFAULT NULL
    ) RETURN CLOB;
    
    -- Apply field mapping
    FUNCTION apply_field_mapping(
        p_message IN CLOB,
        p_mapping IN CLOB
    ) RETURN CLOB;
    
    -- ==========================================================================
    -- MESSAGE AGGREGATION
    -- ==========================================================================
    
    -- Start aggregation for correlation ID
    PROCEDURE start_aggregation(
        p_correlation_id IN VARCHAR2,
        p_aggregation_key IN VARCHAR2,
        p_expected_count IN NUMBER DEFAULT NULL,
        p_timeout_seconds IN NUMBER DEFAULT 300
    );
    
    -- Add message to aggregation
    PROCEDURE add_to_aggregation(
        p_correlation_id IN VARCHAR2,
        p_aggregation_key IN VARCHAR2,
        p_message IN CLOB
    );
    
    -- Check if aggregation is complete
    FUNCTION is_aggregation_complete(
        p_correlation_id IN VARCHAR2,
        p_aggregation_key IN VARCHAR2
    ) RETURN BOOLEAN;
    
    -- Get aggregated result
    PROCEDURE get_aggregated_result(
        p_correlation_id IN VARCHAR2,
        p_aggregation_key IN VARCHAR2,
        p_aggregated_result OUT CLOB
    );
    
    -- Complete aggregation manually
    PROCEDURE complete_aggregation(
        p_correlation_id IN VARCHAR2,
        p_aggregation_key IN VARCHAR2
    );
    
    -- Process timed-out aggregations
    PROCEDURE process_aggregation_timeouts;
    
    -- ==========================================================================
    -- IDEMPOTENCY & DEDUPLICATION
    -- ==========================================================================
    
    -- Check if message is a duplicate
    FUNCTION is_duplicate_message(
        p_message_id IN VARCHAR2,
        p_dedup_window_hours IN NUMBER DEFAULT 24
    ) RETURN BOOLEAN;
    
    -- Check duplicate by content hash
    FUNCTION is_duplicate_by_hash(
        p_message_hash IN VARCHAR2,
        p_tenant_id IN VARCHAR2,
        p_dedup_window_hours IN NUMBER DEFAULT 24
    ) RETURN BOOLEAN;
    
    -- Register message as processed
    PROCEDURE mark_message_processed(
        p_message_id IN VARCHAR2,
        p_correlation_id IN VARCHAR2 DEFAULT NULL,
        p_metadata IN CLOB DEFAULT NULL
    );
    
    -- Generate message hash
    FUNCTION generate_message_hash(
        p_message IN CLOB
    ) RETURN VARCHAR2;
    
    -- ==========================================================================
    -- MESSAGE LIFECYCLE
    -- ==========================================================================
    
    -- Create new message
    FUNCTION create_message(
        p_message_type IN VARCHAR2,
        p_payload IN CLOB,
        p_routing_key IN VARCHAR2 DEFAULT NULL,
        p_correlation_id IN VARCHAR2 DEFAULT NULL,
        p_source_system IN VARCHAR2 DEFAULT NULL
    ) RETURN VARCHAR2;
    
    -- Update message status
    PROCEDURE update_message_status(
        p_message_id IN VARCHAR2,
        p_status IN VARCHAR2,
        p_error_message IN VARCHAR2 DEFAULT NULL
    );
    
    -- Get message by ID
    FUNCTION get_message(
        p_message_id IN VARCHAR2
    ) RETURN integration_message_t;
    
    -- Retry failed message
    PROCEDURE retry_message(
        p_message_id IN VARCHAR2
    );
    
    -- Move to dead letter
    PROCEDURE move_to_dead_letter(
        p_message_id IN VARCHAR2,
        p_reason IN VARCHAR2
    );
    
    -- ==========================================================================
    -- QUERY OPERATIONS
    -- ==========================================================================
    
    -- Get pending messages
    FUNCTION get_pending_messages(
        p_message_type IN VARCHAR2 DEFAULT NULL,
        p_limit IN NUMBER DEFAULT 100
    ) RETURN SYS_REFCURSOR;
    
    -- Get messages by correlation ID
    FUNCTION get_messages_by_correlation(
        p_correlation_id IN VARCHAR2
    ) RETURN SYS_REFCURSOR;
    
    -- Get dead letter messages
    FUNCTION get_dead_letter_messages(
        p_limit IN NUMBER DEFAULT 100
    ) RETURN SYS_REFCURSOR;
    
    -- ==========================================================================
    -- CLEANUP
    -- ==========================================================================
    
    -- Cleanup old dedup records
    PROCEDURE cleanup_dedup_records(
        p_older_than_hours IN NUMBER DEFAULT 24,
        p_deleted_count OUT NUMBER
    );
    
    -- Cleanup completed messages
    PROCEDURE cleanup_completed_messages(
        p_retention_days IN NUMBER DEFAULT 30,
        p_deleted_count OUT NUMBER
    );
    
END integration_pkg;
/

CREATE OR REPLACE PACKAGE BODY integration_pkg AS
    
    -- ==========================================================================
    -- PRIVATE HELPERS
    -- ==========================================================================
    
    FUNCTION generate_message_id RETURN VARCHAR2 IS
    BEGIN
        RETURN SYS_GUID();
    END generate_message_id;
    
    -- ==========================================================================
    -- MESSAGE ROUTING
    -- ==========================================================================
    
    PROCEDURE route_message(
        p_message_id IN VARCHAR2,
        p_message_type IN VARCHAR2,
        p_payload IN CLOB,
        p_routing_key IN VARCHAR2 DEFAULT NULL,
        p_correlation_id IN VARCHAR2 DEFAULT NULL,
        p_source_system IN VARCHAR2 DEFAULT NULL,
        p_destination OUT VARCHAR2
    ) IS
        v_msg_id VARCHAR2(100);
    BEGIN
        -- Generate ID first if not provided
        v_msg_id := NVL(p_message_id, generate_message_id());
        
        -- Check for duplicate (only if caller provided an ID to check)
        IF p_message_id IS NOT NULL AND is_duplicate_message(p_message_id, c_default_dedup_hours) THEN
            RAISE_APPLICATION_ERROR(-20020, 'Duplicate message: ' || p_message_id);
        END IF;
        
        -- Determine destination based on routing rules
        p_destination := get_destination(p_message_type, p_routing_key);
        
        IF p_destination IS NULL THEN
            -- Try content-based routing
            p_destination := evaluate_routing_rules(p_payload, 'DEFAULT');
        END IF;
        
        IF p_destination IS NULL THEN
            RAISE_APPLICATION_ERROR(-20021, 'No routing destination found for message type: ' || p_message_type);
        END IF;
        
        -- Store message (v_msg_id already assigned at start of procedure)
        INSERT INTO integration_messages (
            message_id, correlation_id, message_type, source_system,
            routing_key, destination, payload, status, created_at
        ) VALUES (
            v_msg_id, p_correlation_id, p_message_type, p_source_system,
            p_routing_key, p_destination, p_payload, c_msg_pending, SYSTIMESTAMP
        );
        
        -- Register in dedup table
        INSERT INTO message_dedup (message_id, first_seen, last_seen, process_count)
        VALUES (v_msg_id, SYSTIMESTAMP, SYSTIMESTAMP, 1);
        
        COMMIT;
    END route_message;
    
    FUNCTION evaluate_routing_rules(
        p_content IN CLOB,
        p_rule_set IN VARCHAR2
    ) RETURN VARCHAR2 IS
        v_destination VARCHAR2(200);
        v_json_obj JSON_OBJECT_T;
        v_matches BOOLEAN;
    BEGIN
        -- Parse content
        BEGIN
            v_json_obj := JSON_OBJECT_T.parse(p_content);
        EXCEPTION
            WHEN OTHERS THEN
                RETURN NULL; -- Cannot parse, no routing
        END;
        
        -- Evaluate rules in priority order
        FOR r IN (
            SELECT rule_name, condition_expression, destination
            FROM routing_rules
            WHERE rule_set = p_rule_set
              AND active = 1
            ORDER BY priority
        ) LOOP
            BEGIN
                -- Simple JSON path condition evaluation
                -- Format: $.field = 'value' or $.field EXISTS
                -- In production, this would be more sophisticated
                
                IF r.condition_expression LIKE '$.% EXISTS' THEN
                    DECLARE
                        v_field VARCHAR2(100);
                    BEGIN
                        v_field := REGEXP_REPLACE(r.condition_expression, '^\$\.(\w+) EXISTS$', '\1');
                        IF v_json_obj.has(v_field) THEN
                            v_destination := r.destination;
                            EXIT;
                        END IF;
                    END;
                ELSIF r.condition_expression LIKE '$.% = %' THEN
                    DECLARE
                        v_field VARCHAR2(100);
                        v_expected VARCHAR2(200);
                        v_actual VARCHAR2(200);
                    BEGIN
                        v_field := REGEXP_REPLACE(r.condition_expression, '^\$\.(\w+) = .*$', '\1');
                        v_expected := REGEXP_REPLACE(r.condition_expression, '^.*= ''(.*)''$', '\1');
                        
                        IF v_json_obj.has(v_field) THEN
                            v_actual := v_json_obj.get_String(v_field);
                            IF v_actual = v_expected THEN
                                v_destination := r.destination;
                                EXIT;
                            END IF;
                        END IF;
                    END;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    CONTINUE; -- Skip invalid rules
            END;
        END LOOP;
        
        RETURN v_destination;
    END evaluate_routing_rules;
    
    FUNCTION get_destination(
        p_message_type IN VARCHAR2,
        p_routing_key IN VARCHAR2 DEFAULT NULL
    ) RETURN VARCHAR2 IS
        v_destination VARCHAR2(200);
        v_escaped_key VARCHAR2(600);  -- Larger buffer for escaped characters
    BEGIN
        -- Escape LIKE metacharacters in routing_key to prevent injection
        v_escaped_key := REPLACE(REPLACE(REPLACE(p_routing_key, '\', '\\'), '%', '\%'), '_', '\_');
        
        -- Look up destination from routing rules
        SELECT destination INTO v_destination
        FROM routing_rules
        WHERE message_type = p_message_type
          AND active = 1
          AND (v_escaped_key IS NULL OR 
               condition_expression LIKE '%' || v_escaped_key || '%' ESCAPE '\')
        ORDER BY priority
        FETCH FIRST 1 ROW ONLY;
        
        RETURN v_destination;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            -- Default destinations by message type
            RETURN CASE p_message_type
                WHEN 'CONTRACT_CREATE' THEN 'contract_handler'
                WHEN 'CONTRACT_UPDATE' THEN 'contract_handler'
                WHEN 'CUSTOMER_CREATE' THEN 'customer_handler'
                WHEN 'CUSTOMER_UPDATE' THEN 'customer_handler'
                WHEN 'ETL_BATCH' THEN 'etl_handler'
                ELSE NULL
            END;
    END get_destination;
    
    -- ==========================================================================
    -- MESSAGE TRANSFORMATION
    -- ==========================================================================
    
    FUNCTION transform_message(
        p_source_format IN VARCHAR2,
        p_target_format IN VARCHAR2,
        p_message IN CLOB,
        p_mapping_template IN VARCHAR2 DEFAULT NULL
    ) RETURN CLOB IS
        v_result CLOB;
    BEGIN
        -- Handle format conversions
        IF p_source_format = p_target_format THEN
            RETURN p_message;
        END IF;
        
        IF p_source_format = 'JSON' AND p_target_format = 'XML' THEN
            -- JSON to XML conversion
            -- Using Oracle's JSON_QUERY and XMLELEMENT for conversion
            SELECT XMLELEMENT("data", 
                     XMLAGG(
                       XMLELEMENT(EVALNAME key_name, value_text)
                     )
                   ).getClobVal()
            INTO v_result
            FROM JSON_TABLE(p_message, '$.*' COLUMNS (
                key_name VARCHAR2(100) PATH '$.key',
                value_text VARCHAR2(4000) PATH '$.value'
            ));
            
        ELSIF p_source_format = 'XML' AND p_target_format = 'JSON' THEN
            -- XML to JSON conversion using Oracle 12.2+ JSON generation
            SELECT JSON_OBJECTAGG(
                       KEY element_name VALUE element_value ABSENT ON NULL
                   )
            INTO v_result
            FROM XMLTABLE('/data/*' PASSING XMLTYPE(p_message)
                COLUMNS 
                    element_name VARCHAR2(100) PATH 'name(.)',
                    element_value VARCHAR2(4000) PATH 'text()'
            );
            
        ELSE
            -- Unsupported conversion
            RAISE_APPLICATION_ERROR(-20012, 'Unsupported conversion: ' || p_source_format || ' to ' || p_target_format);
        END IF;
        
        RETURN v_result;
    EXCEPTION
        WHEN OTHERS THEN
            -- Log transformation error for debugging
            INSERT INTO integration_logs (message, error_details, created_at)
            VALUES ('XML to JSON transformation failed', 'Message: ' || SUBSTR(p_message, 1, 1000) || ', Error: ' || SQLERRM, SYSTIMESTAMP);
            -- Return original if transformation fails
            RETURN p_message;
    END transform_message;
    
    FUNCTION apply_field_mapping(
        p_message IN CLOB,
        p_mapping IN CLOB
    ) RETURN CLOB IS
        v_result JSON_OBJECT_T;
        v_source JSON_OBJECT_T;
        v_mapping_obj JSON_OBJECT_T;
        v_keys JSON_KEY_LIST;
    BEGIN
        v_source := JSON_OBJECT_T.parse(p_message);
        v_mapping_obj := JSON_OBJECT_T.parse(p_mapping);
        v_result := JSON_OBJECT_T();
        
        v_keys := v_mapping_obj.get_Keys();
        
        FOR i IN 1..v_keys.COUNT LOOP
            DECLARE
                v_target_field VARCHAR2(100);
                v_source_field VARCHAR2(100);
            BEGIN
                v_target_field := v_keys(i);
                v_source_field := v_mapping_obj.get_String(v_target_field);
                
                IF v_source.has(v_source_field) THEN
                    v_result.put(v_target_field, v_source.get(v_source_field));
                END IF;
            END;
        END LOOP;
        
        RETURN v_result.to_Clob();
    END apply_field_mapping;
    
    -- ==========================================================================
    -- MESSAGE AGGREGATION
    -- ==========================================================================
    
    PROCEDURE start_aggregation(
        p_correlation_id IN VARCHAR2,
        p_aggregation_key IN VARCHAR2,
        p_expected_count IN NUMBER DEFAULT NULL,
        p_timeout_seconds IN NUMBER DEFAULT 300
    ) IS
    BEGIN
        INSERT INTO message_aggregation (
            correlation_id, aggregation_key, expected_count,
            current_count, status, started_at, timeout_at
        ) VALUES (
            p_correlation_id, p_aggregation_key, p_expected_count,
            0, c_agg_pending, SYSTIMESTAMP,
            SYSTIMESTAMP + INTERVAL '1' SECOND * p_timeout_seconds
        );
        
        COMMIT;
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            NULL; -- Already started
    END start_aggregation;
    
    PROCEDURE add_to_aggregation(
        p_correlation_id IN VARCHAR2,
        p_aggregation_key IN VARCHAR2,
        p_message IN CLOB
    ) IS
        v_current_result CLOB;
        v_new_result CLOB;
        v_rows_updated NUMBER;
    BEGIN
        -- Try to lock and update existing aggregation
        BEGIN
            SELECT aggregated_result INTO v_current_result
            FROM message_aggregation
            WHERE correlation_id = p_correlation_id
              AND aggregation_key = p_aggregation_key
              AND status = c_agg_pending
            FOR UPDATE;
            
            -- Append message to aggregated result (as JSON array)
            IF v_current_result IS NULL THEN
                v_new_result := '[' || p_message || ']';
            ELSE
                -- Insert before the closing bracket
                v_new_result := SUBSTR(v_current_result, 1, LENGTH(v_current_result) - 1) || ',' || p_message || ']';
            END IF;
            
            UPDATE message_aggregation SET
                aggregated_result = v_new_result,
                current_count = current_count + 1
            WHERE correlation_id = p_correlation_id
              AND aggregation_key = p_aggregation_key;
            
            COMMIT;
            
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                -- Aggregation doesn't exist - create with initial message (no recursion)
                BEGIN
                    INSERT INTO message_aggregation (
                        correlation_id, aggregation_key, expected_count,
                        current_count, aggregated_result, status, started_at, timeout_at
                    ) VALUES (
                        p_correlation_id, p_aggregation_key, NULL,
                        1, '[' || p_message || ']', c_agg_pending, SYSTIMESTAMP,
                        SYSTIMESTAMP + INTERVAL '300' SECOND
                    );
                    COMMIT;
                EXCEPTION
                    WHEN DUP_VAL_ON_INDEX THEN
                        -- Race: another session created it first - retry update once
                        BEGIN
                            SELECT aggregated_result INTO v_current_result
                            FROM message_aggregation
                            WHERE correlation_id = p_correlation_id
                              AND aggregation_key = p_aggregation_key
                              AND status = c_agg_pending
                            FOR UPDATE;
                            
                            v_new_result := NVL(v_current_result, '[]');
                            IF SUBSTR(v_new_result, -1) = ']' THEN
                                v_new_result := SUBSTR(v_new_result, 1, LENGTH(v_new_result) - 1);
                            END IF;
                            IF v_new_result = '[' THEN
                                v_new_result := '[' || p_message || ']';
                            ELSE
                                v_new_result := v_new_result || ',' || p_message || ']';
                            END IF;
                            
                            UPDATE message_aggregation SET
                                aggregated_result = v_new_result,
                                current_count = current_count + 1
                            WHERE correlation_id = p_correlation_id
                              AND aggregation_key = p_aggregation_key;
                            
                            COMMIT;
                        EXCEPTION
                            WHEN NO_DATA_FOUND THEN
                                -- Row no longer exists, skip update
                                NULL;
                        END;
                END;
        END;
    END add_to_aggregation;
    
    FUNCTION is_aggregation_complete(
        p_correlation_id IN VARCHAR2,
        p_aggregation_key IN VARCHAR2
    ) RETURN BOOLEAN IS
        v_expected NUMBER;
        v_current NUMBER;
        v_status VARCHAR2(20);
    BEGIN
        SELECT expected_count, current_count, status
        INTO v_expected, v_current, v_status
        FROM message_aggregation
        WHERE correlation_id = p_correlation_id
          AND aggregation_key = p_aggregation_key;
        
        IF v_status = c_agg_complete THEN
            RETURN TRUE;
        END IF;
        
        IF v_expected IS NOT NULL AND v_current >= v_expected THEN
            complete_aggregation(p_correlation_id, p_aggregation_key);
            RETURN TRUE;
        END IF;
        
        RETURN FALSE;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN FALSE;
    END is_aggregation_complete;
    
    PROCEDURE get_aggregated_result(
        p_correlation_id IN VARCHAR2,
        p_aggregation_key IN VARCHAR2,
        p_aggregated_result OUT CLOB
    ) IS
    BEGIN
        SELECT aggregated_result INTO p_aggregated_result
        FROM message_aggregation
        WHERE correlation_id = p_correlation_id
          AND aggregation_key = p_aggregation_key;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            p_aggregated_result := NULL;
    END get_aggregated_result;
    
    PROCEDURE complete_aggregation(
        p_correlation_id IN VARCHAR2,
        p_aggregation_key IN VARCHAR2
    ) IS
    BEGIN
        UPDATE message_aggregation SET
            status = c_agg_complete,
            completed_at = SYSTIMESTAMP
        WHERE correlation_id = p_correlation_id
          AND aggregation_key = p_aggregation_key
          AND status = c_agg_pending;
        
        COMMIT;
    END complete_aggregation;
    
    PROCEDURE process_aggregation_timeouts IS
    BEGIN
        UPDATE message_aggregation SET
            status = c_agg_timeout,
            completed_at = SYSTIMESTAMP
        WHERE status = c_agg_pending
          AND timeout_at < SYSTIMESTAMP;
        
        COMMIT;
    END process_aggregation_timeouts;
    
    -- ==========================================================================
    -- IDEMPOTENCY & DEDUPLICATION
    -- ==========================================================================
    
    FUNCTION is_duplicate_message(
        p_message_id IN VARCHAR2,
        p_dedup_window_hours IN NUMBER DEFAULT 24
    ) RETURN BOOLEAN IS
        v_count NUMBER;
        v_cutoff TIMESTAMP;
    BEGIN
        v_cutoff := SYSTIMESTAMP - INTERVAL '1' HOUR * p_dedup_window_hours;
        
        SELECT COUNT(*) INTO v_count
        FROM message_dedup
        WHERE message_id = p_message_id
          AND first_seen >= v_cutoff;
        
        IF v_count > 0 THEN
            -- Update last seen
            UPDATE message_dedup SET
                last_seen = SYSTIMESTAMP,
                process_count = process_count + 1
            WHERE message_id = p_message_id;
            
            RETURN TRUE;
        END IF;
        
        RETURN FALSE;
    END is_duplicate_message;
    
    FUNCTION is_duplicate_by_hash(
        p_message_hash IN VARCHAR2,
        p_tenant_id IN VARCHAR2,
        p_dedup_window_hours IN NUMBER DEFAULT 24
    ) RETURN BOOLEAN IS
        v_count NUMBER;
        v_cutoff TIMESTAMP;
    BEGIN
        v_cutoff := SYSTIMESTAMP - INTERVAL '1' HOUR * p_dedup_window_hours;
        
        SELECT COUNT(*) INTO v_count
        FROM message_dedup
        WHERE message_hash = p_message_hash
          AND tenant_id = p_tenant_id
          AND first_seen >= v_cutoff;
        
        RETURN v_count > 0;
    END is_duplicate_by_hash;
    
    PROCEDURE mark_message_processed(
        p_message_id IN VARCHAR2,
        p_correlation_id IN VARCHAR2 DEFAULT NULL,
        p_metadata IN CLOB DEFAULT NULL
    ) IS
    BEGIN
        -- Update message status
        UPDATE integration_messages SET
            status = c_msg_completed,
            processed_at = SYSTIMESTAMP
        WHERE message_id = p_message_id;
        
        -- Ensure dedup record exists
        MERGE INTO message_dedup d
        USING (SELECT p_message_id as msg_id FROM DUAL) s
        ON (d.message_id = s.msg_id)
        WHEN MATCHED THEN
            UPDATE SET last_seen = SYSTIMESTAMP, process_count = d.process_count + 1
        WHEN NOT MATCHED THEN
            INSERT (message_id, first_seen, last_seen, process_count)
            VALUES (p_message_id, SYSTIMESTAMP, SYSTIMESTAMP, 1);
        
        COMMIT;
    END mark_message_processed;
    
    FUNCTION generate_message_hash(
        p_message IN CLOB
    ) RETURN VARCHAR2 IS
        v_blob BLOB;
        v_dest_offset INTEGER := 1;
        v_src_offset INTEGER := 1;
        v_lang_context INTEGER := DBMS_LOB.DEFAULT_LANG_CTX;
        v_warning INTEGER;
        v_hash VARCHAR2(64);
    BEGIN
        -- Convert CLOB to BLOB for DBMS_CRYPTO.HASH (handles >32KB)
        DBMS_LOB.CREATETEMPORARY(v_blob, TRUE);
        DBMS_LOB.CONVERTTOBLOB(
            dest_lob => v_blob,
            src_clob => p_message,
            amount => DBMS_LOB.LOBMAXSIZE,
            dest_offset => v_dest_offset,
            src_offset => v_src_offset,
            blob_csid => DBMS_LOB.DEFAULT_CSID,
            lang_context => v_lang_context,
            warning => v_warning
        );
        
        v_hash := RAWTOHEX(DBMS_CRYPTO.HASH(v_blob, DBMS_CRYPTO.HASH_SH256));
        DBMS_LOB.FREETEMPORARY(v_blob);
        RETURN v_hash;
    EXCEPTION
        WHEN OTHERS THEN
            IF v_blob IS NOT NULL THEN
                DBMS_LOB.FREETEMPORARY(v_blob);
            END IF;
            RAISE;
    END generate_message_hash;
    
    -- ==========================================================================
    -- MESSAGE LIFECYCLE
    -- ==========================================================================
    
    FUNCTION create_message(
        p_message_type IN VARCHAR2,
        p_payload IN CLOB,
        p_routing_key IN VARCHAR2 DEFAULT NULL,
        p_correlation_id IN VARCHAR2 DEFAULT NULL,
        p_source_system IN VARCHAR2 DEFAULT NULL
    ) RETURN VARCHAR2 IS
        v_message_id VARCHAR2(100);
    BEGIN
        v_message_id := generate_message_id();
        
        INSERT INTO integration_messages (
            message_id, correlation_id, message_type, source_system,
            routing_key, payload, status, created_at, max_retries
        ) VALUES (
            v_message_id, p_correlation_id, p_message_type, p_source_system,
            p_routing_key, p_payload, c_msg_pending, SYSTIMESTAMP, c_default_max_retries
        );
        
        COMMIT;
        RETURN v_message_id;
    END create_message;
    
    PROCEDURE update_message_status(
        p_message_id IN VARCHAR2,
        p_status IN VARCHAR2,
        p_error_message IN VARCHAR2 DEFAULT NULL
    ) IS
    BEGIN
        UPDATE integration_messages SET
            status = p_status,
            error_message = p_error_message,
            processed_at = CASE WHEN p_status IN (c_msg_completed, c_msg_failed, c_msg_dead_letter) 
                               THEN SYSTIMESTAMP ELSE processed_at END
        WHERE message_id = p_message_id;
        
        COMMIT;
    END update_message_status;
    
    FUNCTION get_message(
        p_message_id IN VARCHAR2
    ) RETURN integration_message_t IS
        v_msg integration_message_t;
    BEGIN
        SELECT integration_message_t(
            message_id, correlation_id, message_type, source_system,
            routing_key, payload, status, created_at, processed_at,
            retry_count, error_message
        )
        INTO v_msg
        FROM integration_messages
        WHERE message_id = p_message_id;
        
        RETURN v_msg;
    END get_message;
    
    PROCEDURE retry_message(
        p_message_id IN VARCHAR2
    ) IS
        v_retry_count NUMBER;
        v_max_retries NUMBER;
    BEGIN
        SELECT retry_count, max_retries INTO v_retry_count, v_max_retries
        FROM integration_messages
        WHERE message_id = p_message_id;
        
        IF v_retry_count >= v_max_retries THEN
            move_to_dead_letter(p_message_id, 'Max retries exceeded');
            RETURN;
        END IF;
        
        UPDATE integration_messages SET
            status = c_msg_pending,
            retry_count = retry_count + 1,
            next_retry_at = SYSTIMESTAMP + POWER(2, retry_count) * INTERVAL '1' MINUTE,
            error_message = NULL
        WHERE message_id = p_message_id;
        
        COMMIT;
    END retry_message;
    
    PROCEDURE move_to_dead_letter(
        p_message_id IN VARCHAR2,
        p_reason IN VARCHAR2
    ) IS
    BEGIN
        UPDATE integration_messages SET
            status = c_msg_dead_letter,
            error_message = p_reason,
            processed_at = SYSTIMESTAMP
        WHERE message_id = p_message_id;
        
        COMMIT;
    END move_to_dead_letter;
    
    -- ==========================================================================
    -- QUERY OPERATIONS
    -- ==========================================================================
    
    FUNCTION get_pending_messages(
        p_message_type IN VARCHAR2 DEFAULT NULL,
        p_limit IN NUMBER DEFAULT 100
    ) RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT *
            FROM integration_messages
            WHERE status = c_msg_pending
              AND (p_message_type IS NULL OR message_type = p_message_type)
              AND (next_retry_at IS NULL OR next_retry_at <= SYSTIMESTAMP)
            ORDER BY created_at
            FETCH FIRST p_limit ROWS ONLY;
            
        RETURN v_cursor;
    END get_pending_messages;
    
    FUNCTION get_messages_by_correlation(
        p_correlation_id IN VARCHAR2
    ) RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT *
            FROM integration_messages
            WHERE correlation_id = p_correlation_id
            ORDER BY created_at;
            
        RETURN v_cursor;
    END get_messages_by_correlation;
    
    FUNCTION get_dead_letter_messages(
        p_limit IN NUMBER DEFAULT 100
    ) RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT *
            FROM integration_messages
            WHERE status = c_msg_dead_letter
            ORDER BY processed_at DESC
            FETCH FIRST p_limit ROWS ONLY;
            
        RETURN v_cursor;
    END get_dead_letter_messages;
    
    -- ==========================================================================
    -- CLEANUP
    -- ==========================================================================
    
    PROCEDURE cleanup_dedup_records(
        p_older_than_hours IN NUMBER DEFAULT 24,
        p_deleted_count OUT NUMBER
    ) IS
        v_cutoff TIMESTAMP;
    BEGIN
        v_cutoff := SYSTIMESTAMP - INTERVAL '1' HOUR * p_older_than_hours;
        
        DELETE FROM message_dedup
        WHERE last_seen < v_cutoff;
        
        p_deleted_count := SQL%ROWCOUNT;
        COMMIT;
    END cleanup_dedup_records;
    
    PROCEDURE cleanup_completed_messages(
        p_retention_days IN NUMBER DEFAULT 30,
        p_deleted_count OUT NUMBER
    ) IS
        v_cutoff TIMESTAMP;
    BEGIN
        v_cutoff := SYSTIMESTAMP - INTERVAL '1' DAY * p_retention_days;
        
        DELETE FROM integration_messages
        WHERE status IN (c_msg_completed, c_msg_dead_letter)
          AND processed_at < v_cutoff;
        
        p_deleted_count := SQL%ROWCOUNT;
        COMMIT;
    END cleanup_completed_messages;
    
END integration_pkg;
/
