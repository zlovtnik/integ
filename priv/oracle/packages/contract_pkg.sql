-- CONTRACT_PKG - Contract Operations Package
-- Purpose: CRUD and business logic for contracts via PL/SQL
-- Author: GprintEx Team
-- Date: 2026-01-27

CREATE OR REPLACE PACKAGE contract_pkg AS
    -- ==========================================================================
    -- CONSTANTS
    -- ==========================================================================
    
    -- Status constants
    c_status_draft      CONSTANT VARCHAR2(20) := 'DRAFT';
    c_status_pending    CONSTANT VARCHAR2(20) := 'PENDING';
    c_status_active     CONSTANT VARCHAR2(20) := 'ACTIVE';
    c_status_suspended  CONSTANT VARCHAR2(20) := 'SUSPENDED';
    c_status_cancelled  CONSTANT VARCHAR2(20) := 'CANCELLED';
    c_status_completed  CONSTANT VARCHAR2(20) := 'COMPLETED';
    
    -- Contract type constants
    c_type_service      CONSTANT VARCHAR2(20) := 'SERVICE';
    c_type_recurring    CONSTANT VARCHAR2(20) := 'RECURRING';
    c_type_project      CONSTANT VARCHAR2(20) := 'PROJECT';
    
    -- ==========================================================================
    -- EXCEPTIONS
    -- ==========================================================================
    
    e_validation_failed EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_validation_failed, -20001);
    
    e_not_found EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_not_found, -20002);
    
    e_invalid_transition EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_invalid_transition, -20003);
    
    e_duplicate_contract EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_duplicate_contract, -20004);
    
    -- ==========================================================================
    -- INSERT OPERATIONS
    -- ==========================================================================
    
    -- Insert a single contract
    -- Returns: New contract ID
    FUNCTION insert_contract(
        p_contract IN contract_t,
        p_user IN VARCHAR2
    ) RETURN NUMBER;
    
    -- Bulk insert with validation
    -- Returns metadata with counts, populates error array
    PROCEDURE bulk_insert_contracts(
        p_contracts IN contract_tab,
        p_user IN VARCHAR2,
        p_metadata OUT transform_metadata_t,
        p_errors OUT validation_results_tab
    );
    
    -- ==========================================================================
    -- QUERY OPERATIONS
    -- ==========================================================================
    
    -- Get contract by ID
    FUNCTION get_contract_by_id(
        p_tenant_id IN VARCHAR2,
        p_id IN NUMBER
    ) RETURN contract_t;
    
    -- Get contract by number
    FUNCTION get_contract_by_number(
        p_tenant_id IN VARCHAR2,
        p_contract_number IN VARCHAR2
    ) RETURN contract_t;
    
    -- Get contracts with filter (pipelined for streaming)
    FUNCTION get_contracts_by_filter(
        p_tenant_id IN VARCHAR2,
        p_status IN VARCHAR2 DEFAULT NULL,
        p_customer_id IN NUMBER DEFAULT NULL,
        p_start_date IN DATE DEFAULT NULL,
        p_end_date IN DATE DEFAULT NULL,
        p_contract_type IN VARCHAR2 DEFAULT NULL
    ) RETURN contract_tab PIPELINED;
    
    -- Count contracts matching filter
    FUNCTION count_contracts(
        p_tenant_id IN VARCHAR2,
        p_status IN VARCHAR2 DEFAULT NULL,
        p_customer_id IN NUMBER DEFAULT NULL
    ) RETURN NUMBER;
    
    -- ==========================================================================
    -- UPDATE OPERATIONS
    -- ==========================================================================
    
    -- Update contract (full update)
    PROCEDURE update_contract(
        p_contract IN contract_t,
        p_user IN VARCHAR2,
        p_validation OUT validation_result_t
    );
    
    -- Update contract status with state machine validation
    PROCEDURE update_contract_status(
        p_tenant_id IN VARCHAR2,
        p_id IN NUMBER,
        p_new_status IN VARCHAR2,
        p_user IN VARCHAR2,
        p_reason IN VARCHAR2 DEFAULT NULL,
        p_validation OUT validation_result_t
    );
    
    -- ==========================================================================
    -- DELETE OPERATIONS
    -- ==========================================================================
    
    -- Soft delete contract (sets status to CANCELLED)
    PROCEDURE soft_delete_contract(
        p_tenant_id IN VARCHAR2,
        p_id IN NUMBER,
        p_user IN VARCHAR2,
        p_reason IN VARCHAR2 DEFAULT NULL
    );
    
    -- ==========================================================================
    -- VALIDATION
    -- ==========================================================================
    
    -- Validate contract data
    FUNCTION validate_contract(
        p_contract IN contract_t
    ) RETURN validation_results_tab;
    
    -- Check if status transition is valid
    FUNCTION is_valid_transition(
        p_current_status IN VARCHAR2,
        p_new_status IN VARCHAR2
    ) RETURN BOOLEAN;
    
    -- Get allowed status transitions
    FUNCTION get_allowed_transitions(
        p_current_status IN VARCHAR2
    ) RETURN SYS.ODCIVARCHAR2LIST;
    
    -- ==========================================================================
    -- BUSINESS LOGIC
    -- ==========================================================================
    
    -- Calculate contract total from items
    FUNCTION calculate_contract_total(
        p_contract_id IN NUMBER,
        p_tenant_id IN VARCHAR2
    ) RETURN NUMBER;
    
    -- Get contract statistics (returns cursor for complex aggregations)
    FUNCTION get_contract_statistics(
        p_tenant_id IN VARCHAR2,
        p_start_date IN DATE,
        p_end_date IN DATE
    ) RETURN SYS_REFCURSOR;
    
    -- Check contract expiration
    FUNCTION is_expiring_soon(
        p_contract_id IN NUMBER,
        p_tenant_id IN VARCHAR2,
        p_days_threshold IN NUMBER DEFAULT 30
    ) RETURN BOOLEAN;
    
    -- Auto-renew eligible contracts
    PROCEDURE process_auto_renewals(
        p_tenant_id IN VARCHAR2,
        p_user IN VARCHAR2,
        p_renewed_count OUT NUMBER,
        p_errors OUT validation_results_tab
    );
    
END contract_pkg;
/

CREATE OR REPLACE PACKAGE BODY contract_pkg AS
    
    -- ==========================================================================
    -- PRIVATE HELPER FUNCTIONS
    -- ==========================================================================
    
    -- Build contract from row data
    FUNCTION row_to_contract(
        p_row IN contracts%ROWTYPE
    ) RETURN contract_t IS
        v_contract contract_t;
    BEGIN
        v_contract := contract_t(
            p_row.tenant_id,
            p_row.contract_number,
            p_row.customer_id,
            p_row.start_date
        );
        
        v_contract.id := p_row.id;
        v_contract.contract_type := p_row.contract_type;
        v_contract.end_date := p_row.end_date;
        v_contract.duration_months := p_row.duration_months;
        v_contract.auto_renew := p_row.auto_renew;
        v_contract.total_value := p_row.total_value;
        v_contract.payment_terms := p_row.payment_terms;
        v_contract.billing_cycle := p_row.billing_cycle;
        v_contract.status := p_row.status;
        v_contract.signed_at := p_row.signed_at;
        v_contract.signed_by := p_row.signed_by;
        v_contract.notes := p_row.notes;
        v_contract.created_at := p_row.created_at;
        v_contract.updated_at := p_row.updated_at;
        v_contract.created_by := p_row.created_by;
        v_contract.updated_by := p_row.updated_by;
        
        RETURN v_contract;
    END row_to_contract;
    
    -- Record status change in history
    PROCEDURE record_status_change(
        p_tenant_id IN VARCHAR2,
        p_contract_id IN NUMBER,
        p_old_status IN VARCHAR2,
        p_new_status IN VARCHAR2,
        p_user IN VARCHAR2,
        p_reason IN VARCHAR2 DEFAULT NULL
    ) IS
    BEGIN
        INSERT INTO contract_status_history (
            tenant_id, contract_id, previous_status, new_status,
            changed_at, changed_by, change_reason
        ) VALUES (
            p_tenant_id, p_contract_id, p_old_status, p_new_status,
            SYSTIMESTAMP, p_user, p_reason
        );
    END record_status_change;
    
    -- ==========================================================================
    -- INSERT OPERATIONS
    -- ==========================================================================
    
    FUNCTION insert_contract(
        p_contract IN contract_t,
        p_user IN VARCHAR2
    ) RETURN NUMBER IS
        v_id NUMBER;
        v_errors validation_results_tab;
        v_existing NUMBER;
    BEGIN
        -- Validate contract
        v_errors := validate_contract(p_contract);
        IF v_errors IS NOT NULL AND v_errors.COUNT > 0 THEN
            RAISE_APPLICATION_ERROR(-20001, 'Validation failed: ' || v_errors(1).error_message);
        END IF;
        
        -- Insert contract (relies on unique constraint on tenant_id, contract_number)
        BEGIN
            INSERT INTO contracts (
                tenant_id, contract_number, contract_type, customer_id,
                start_date, end_date, duration_months, auto_renew,
                total_value, payment_terms, billing_cycle, status,
                signed_at, signed_by, notes,
                created_at, updated_at, created_by, updated_by
            ) VALUES (
                p_contract.tenant_id,
                p_contract.contract_number,
                NVL(p_contract.contract_type, c_type_service),
                p_contract.customer_id,
                p_contract.start_date,
                p_contract.end_date,
            p_contract.duration_months,
            NVL(p_contract.auto_renew, 0),
            NVL(p_contract.total_value, 0),
            p_contract.payment_terms,
            NVL(p_contract.billing_cycle, 'MONTHLY'),
            NVL(p_contract.status, c_status_draft),
            p_contract.signed_at,
            p_contract.signed_by,
            p_contract.notes,
            SYSTIMESTAMP,
            SYSTIMESTAMP,
            p_user,
            p_user
        )
        RETURNING id INTO v_id;
        EXCEPTION
            WHEN DUP_VAL_ON_INDEX THEN
                RAISE_APPLICATION_ERROR(-20004, 'Contract number already exists: ' || p_contract.contract_number);
        END;
        
        -- Record initial status
        record_status_change(
            p_contract.tenant_id, v_id, NULL,
            NVL(p_contract.status, c_status_draft), p_user, 'Initial creation'
        );
        
        RETURN v_id;
    END insert_contract;
    
    PROCEDURE bulk_insert_contracts(
        p_contracts IN contract_tab,
        p_user IN VARCHAR2,
        p_metadata OUT transform_metadata_t,
        p_errors OUT validation_results_tab
    ) IS
        v_id NUMBER;
        v_validation validation_results_tab;
        v_error validation_result_t;
    BEGIN
        p_metadata := transform_metadata_t('BULK_INSERT');
        p_metadata.record_count := p_contracts.COUNT;
        p_errors := validation_results_tab();
        
        FOR i IN 1..p_contracts.COUNT LOOP
            BEGIN
                v_validation := validate_contract(p_contracts(i));
                
                IF v_validation IS NULL OR v_validation.COUNT = 0 THEN
                    v_id := insert_contract(p_contracts(i), p_user);
                    p_metadata.success_count := p_metadata.success_count + 1;
                ELSE
                    p_metadata.error_count := p_metadata.error_count + 1;
                    FOR j IN 1..v_validation.COUNT LOOP
                        p_errors.EXTEND;
                        p_errors(p_errors.COUNT) := v_validation(j);
                    END LOOP;
                END IF;
                
            EXCEPTION
                WHEN OTHERS THEN
                    p_metadata.error_count := p_metadata.error_count + 1;
                    v_error := validation_result_t(0, 'INSERT_ERROR', SQLERRM, 'contract[' || i || ']');
                    p_errors.EXTEND;
                    p_errors(p_errors.COUNT) := v_error;
            END;
        END LOOP;
        
        p_metadata.transform_timestamp := SYSTIMESTAMP;
    END bulk_insert_contracts;
    
    -- ==========================================================================
    -- QUERY OPERATIONS
    -- ==========================================================================
    
    FUNCTION get_contract_by_id(
        p_tenant_id IN VARCHAR2,
        p_id IN NUMBER
    ) RETURN contract_t IS
        v_row contracts%ROWTYPE;
    BEGIN
        SELECT * INTO v_row
        FROM contracts
        WHERE tenant_id = p_tenant_id AND id = p_id;
        
        RETURN row_to_contract(v_row);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20002, 'Contract not found: ' || p_id);
    END get_contract_by_id;
    
    FUNCTION get_contract_by_number(
        p_tenant_id IN VARCHAR2,
        p_contract_number IN VARCHAR2
    ) RETURN contract_t IS
        v_row contracts%ROWTYPE;
    BEGIN
        SELECT * INTO v_row
        FROM contracts
        WHERE tenant_id = p_tenant_id AND contract_number = p_contract_number;
        
        RETURN row_to_contract(v_row);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20002, 'Contract not found: ' || p_contract_number);
    END get_contract_by_number;
    
    FUNCTION get_contracts_by_filter(
        p_tenant_id IN VARCHAR2,
        p_status IN VARCHAR2 DEFAULT NULL,
        p_customer_id IN NUMBER DEFAULT NULL,
        p_start_date IN DATE DEFAULT NULL,
        p_end_date IN DATE DEFAULT NULL,
        p_contract_type IN VARCHAR2 DEFAULT NULL
    ) RETURN contract_tab PIPELINED IS
        v_row contracts%ROWTYPE;
    BEGIN
        FOR v_row IN (
            SELECT *
            FROM contracts
            WHERE tenant_id = p_tenant_id
              AND (p_status IS NULL OR status = p_status)
              AND (p_customer_id IS NULL OR customer_id = p_customer_id)
              AND (p_start_date IS NULL OR start_date >= p_start_date)
              AND (p_end_date IS NULL OR start_date <= p_end_date)
              AND (p_contract_type IS NULL OR contract_type = p_contract_type)
            ORDER BY created_at DESC
        ) LOOP
            PIPE ROW(row_to_contract(v_row));
        END LOOP;
        
        RETURN;
    END get_contracts_by_filter;
    
    FUNCTION count_contracts(
        p_tenant_id IN VARCHAR2,
        p_status IN VARCHAR2 DEFAULT NULL,
        p_customer_id IN NUMBER DEFAULT NULL
    ) RETURN NUMBER IS
        v_count NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_count
        FROM contracts
        WHERE tenant_id = p_tenant_id
          AND (p_status IS NULL OR status = p_status)
          AND (p_customer_id IS NULL OR customer_id = p_customer_id);
          
        RETURN v_count;
    END count_contracts;
    
    -- ==========================================================================
    -- UPDATE OPERATIONS
    -- ==========================================================================
    
    PROCEDURE update_contract(
        p_contract IN contract_t,
        p_user IN VARCHAR2,
        p_validation OUT validation_result_t
    ) IS
        v_errors validation_results_tab;
        v_existing contracts%ROWTYPE;
    BEGIN
        -- Check if contract exists
        BEGIN
            SELECT * INTO v_existing
            FROM contracts
            WHERE tenant_id = p_contract.tenant_id AND id = p_contract.id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                p_validation := validation_result_t(0, 'NOT_FOUND', 'Contract not found', 'id');
                RETURN;
        END;
        
        -- Validate updates
        v_errors := validate_contract(p_contract);
        IF v_errors IS NOT NULL AND v_errors.COUNT > 0 THEN
            p_validation := v_errors(1);
            RETURN;
        END IF;
        
        -- Update contract
        UPDATE contracts SET
            contract_type = NVL(p_contract.contract_type, contract_type),
            customer_id = NVL(p_contract.customer_id, customer_id),
            start_date = NVL(p_contract.start_date, start_date),
            end_date = p_contract.end_date,
            duration_months = p_contract.duration_months,
            auto_renew = NVL(p_contract.auto_renew, auto_renew),
            total_value = NVL(p_contract.total_value, total_value),
            payment_terms = p_contract.payment_terms,
            billing_cycle = NVL(p_contract.billing_cycle, billing_cycle),
            signed_at = p_contract.signed_at,
            signed_by = p_contract.signed_by,
            notes = p_contract.notes,
            updated_at = SYSTIMESTAMP,
            updated_by = p_user
        WHERE tenant_id = p_contract.tenant_id AND id = p_contract.id;
        
        p_validation := validation_result_t(1, NULL, NULL, NULL);
    END update_contract;
    
    PROCEDURE update_contract_status(
        p_tenant_id IN VARCHAR2,
        p_id IN NUMBER,
        p_new_status IN VARCHAR2,
        p_user IN VARCHAR2,
        p_reason IN VARCHAR2 DEFAULT NULL,
        p_validation OUT validation_result_t
    ) IS
        v_current_status VARCHAR2(20);
    BEGIN
        -- Get current status with row lock to prevent race conditions
        BEGIN
            SELECT status INTO v_current_status
            FROM contracts
            WHERE tenant_id = p_tenant_id AND id = p_id
            FOR UPDATE;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                p_validation := validation_result_t(0, 'NOT_FOUND', 'Contract not found', 'id');
                RETURN;
        END;
        
        -- Check if transition is valid
        IF NOT is_valid_transition(v_current_status, p_new_status) THEN
            p_validation := validation_result_t(
                0, 'INVALID_TRANSITION',
                'Cannot transition from ' || v_current_status || ' to ' || p_new_status,
                'status'
            );
            RETURN;
        END IF;
        
        -- Update status
        UPDATE contracts SET
            status = p_new_status,
            updated_at = SYSTIMESTAMP,
            updated_by = p_user
        WHERE tenant_id = p_tenant_id AND id = p_id;
        
        -- Record history
        record_status_change(p_tenant_id, p_id, v_current_status, p_new_status, p_user, p_reason);
        
        p_validation := validation_result_t(1, NULL, NULL, NULL);
    END update_contract_status;
    
    -- ==========================================================================
    -- DELETE OPERATIONS
    -- ==========================================================================
    
    PROCEDURE soft_delete_contract(
        p_tenant_id IN VARCHAR2,
        p_id IN NUMBER,
        p_user IN VARCHAR2,
        p_reason IN VARCHAR2 DEFAULT NULL
    ) IS
        v_validation validation_result_t;
    BEGIN
        update_contract_status(
            p_tenant_id, p_id, c_status_cancelled,
            p_user, NVL(p_reason, 'Soft delete requested'), v_validation
        );
        
        IF v_validation.is_valid = 0 THEN
            RAISE_APPLICATION_ERROR(-20001, v_validation.error_message);
        END IF;
    END soft_delete_contract;
    
    -- ==========================================================================
    -- VALIDATION
    -- ==========================================================================
    
    FUNCTION validate_contract(
        p_contract IN contract_t
    ) RETURN validation_results_tab IS
        v_errors validation_results_tab := validation_results_tab();
        
        PROCEDURE add_error(p_code VARCHAR2, p_message VARCHAR2, p_field VARCHAR2) IS
        BEGIN
            v_errors.EXTEND;
            v_errors(v_errors.COUNT) := validation_result_t(0, p_code, p_message, p_field);
        END;
    BEGIN
        -- Required field validation
        IF p_contract.tenant_id IS NULL OR LENGTH(TRIM(p_contract.tenant_id)) = 0 THEN
            add_error('REQUIRED', 'tenant_id is required', 'tenant_id');
        END IF;
        
        IF p_contract.contract_number IS NULL OR LENGTH(TRIM(p_contract.contract_number)) = 0 THEN
            add_error('REQUIRED', 'contract_number is required', 'contract_number');
        END IF;
        
        IF p_contract.customer_id IS NULL THEN
            add_error('REQUIRED', 'customer_id is required', 'customer_id');
        END IF;
        
        IF p_contract.start_date IS NULL THEN
            add_error('REQUIRED', 'start_date is required', 'start_date');
        END IF;
        
        -- Date validation
        IF p_contract.start_date IS NOT NULL AND p_contract.end_date IS NOT NULL THEN
            IF p_contract.end_date < p_contract.start_date THEN
                add_error('INVALID_DATE', 'end_date cannot be before start_date', 'end_date');
            END IF;
        END IF;
        
        -- Status validation
        IF p_contract.status IS NOT NULL THEN
            IF p_contract.status NOT IN (c_status_draft, c_status_pending, c_status_active,
                                          c_status_suspended, c_status_cancelled, c_status_completed) THEN
                add_error('INVALID_STATUS', 'Invalid status: ' || p_contract.status, 'status');
            END IF;
        END IF;
        
        -- Contract type validation
        IF p_contract.contract_type IS NOT NULL THEN
            IF p_contract.contract_type NOT IN (c_type_service, c_type_recurring, c_type_project) THEN
                add_error('INVALID_TYPE', 'Invalid contract_type: ' || p_contract.contract_type, 'contract_type');
            END IF;
        END IF;
        
        -- Value validation
        IF p_contract.total_value IS NOT NULL AND p_contract.total_value < 0 THEN
            add_error('INVALID_VALUE', 'total_value cannot be negative', 'total_value');
        END IF;
        
        RETURN v_errors;
    END validate_contract;
    
    FUNCTION is_valid_transition(
        p_current_status IN VARCHAR2,
        p_new_status IN VARCHAR2
    ) RETURN BOOLEAN IS
        v_allowed SYS.ODCIVARCHAR2LIST;
    BEGIN
        v_allowed := get_allowed_transitions(p_current_status);
        
        FOR i IN 1..v_allowed.COUNT LOOP
            IF v_allowed(i) = p_new_status THEN
                RETURN TRUE;
            END IF;
        END LOOP;
        
        RETURN FALSE;
    END is_valid_transition;
    
    FUNCTION get_allowed_transitions(
        p_current_status IN VARCHAR2
    ) RETURN SYS.ODCIVARCHAR2LIST IS
    BEGIN
        RETURN CASE p_current_status
            WHEN c_status_draft THEN SYS.ODCIVARCHAR2LIST(c_status_pending, c_status_cancelled)
            WHEN c_status_pending THEN SYS.ODCIVARCHAR2LIST(c_status_active, c_status_draft, c_status_cancelled)
            WHEN c_status_active THEN SYS.ODCIVARCHAR2LIST(c_status_suspended, c_status_completed, c_status_cancelled)
            WHEN c_status_suspended THEN SYS.ODCIVARCHAR2LIST(c_status_active, c_status_cancelled)
            WHEN c_status_cancelled THEN SYS.ODCIVARCHAR2LIST()
            WHEN c_status_completed THEN SYS.ODCIVARCHAR2LIST()
            ELSE SYS.ODCIVARCHAR2LIST()
        END;
    END get_allowed_transitions;
    
    -- ==========================================================================
    -- BUSINESS LOGIC
    -- ==========================================================================
    
    FUNCTION calculate_contract_total(
        p_contract_id IN NUMBER,
        p_tenant_id IN VARCHAR2
    ) RETURN NUMBER IS
        v_total NUMBER := 0;
    BEGIN
        SELECT NVL(SUM(
            quantity * unit_price * (1 - NVL(discount_pct, 0) / 100)
        ), 0) INTO v_total
        FROM contract_items
        WHERE tenant_id = p_tenant_id AND contract_id = p_contract_id;
        
        RETURN v_total;
    END calculate_contract_total;
    
    FUNCTION get_contract_statistics(
        p_tenant_id IN VARCHAR2,
        p_start_date IN DATE,
        p_end_date IN DATE
    ) RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT
                status,
                contract_type,
                COUNT(*) as contract_count,
                SUM(total_value) as total_value,
                AVG(total_value) as avg_value,
                MIN(start_date) as earliest_start,
                MAX(end_date) as latest_end
            FROM contracts
            WHERE tenant_id = p_tenant_id
              AND start_date >= p_start_date
              AND start_date <= p_end_date
            GROUP BY status, contract_type
            ORDER BY status, contract_type;
            
        RETURN v_cursor;
    END get_contract_statistics;
    
    FUNCTION is_expiring_soon(
        p_contract_id IN NUMBER,
        p_tenant_id IN VARCHAR2,
        p_days_threshold IN NUMBER DEFAULT 30
    ) RETURN BOOLEAN IS
        v_end_date DATE;
    BEGIN
        SELECT end_date INTO v_end_date
        FROM contracts
        WHERE tenant_id = p_tenant_id AND id = p_contract_id;
        
        IF v_end_date IS NULL THEN
            RETURN FALSE;
        END IF;
        
        RETURN v_end_date <= SYSDATE + p_days_threshold;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN FALSE;
    END is_expiring_soon;
    
    PROCEDURE process_auto_renewals(
        p_tenant_id IN VARCHAR2,
        p_user IN VARCHAR2,
        p_renewed_count OUT NUMBER,
        p_errors OUT validation_results_tab
    ) IS
        v_error validation_result_t;
        v_new_end_date DATE;
    BEGIN
        p_renewed_count := 0;
        p_errors := validation_results_tab();
        
        FOR r IN (
            SELECT id, end_date, duration_months
            FROM contracts
            WHERE tenant_id = p_tenant_id
              AND status = c_status_active
              AND auto_renew = 1
              AND end_date <= SYSDATE
        ) LOOP
            BEGIN
                v_new_end_date := ADD_MONTHS(r.end_date, NVL(r.duration_months, 12));
                
                UPDATE contracts SET
                    end_date = v_new_end_date,
                    updated_at = SYSTIMESTAMP,
                    updated_by = p_user
                WHERE id = r.id AND tenant_id = p_tenant_id;
                
                p_renewed_count := p_renewed_count + 1;
            EXCEPTION
                WHEN OTHERS THEN
                    v_error := validation_result_t(0, 'RENEWAL_ERROR', SQLERRM, 'contract_id=' || r.id);
                    p_errors.EXTEND;
                    p_errors(p_errors.COUNT) := v_error;
            END;
        END LOOP;
    END process_auto_renewals;
    
END contract_pkg;
/
