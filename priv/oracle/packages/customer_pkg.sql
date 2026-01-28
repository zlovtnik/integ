-- CUSTOMER_PKG - Customer Operations Package
-- Purpose: CRUD and business logic for customers via PL/SQL
-- Author: GprintEx Team
-- Date: 2026-01-27

CREATE OR REPLACE PACKAGE customer_pkg AS
    -- ==========================================================================
    -- CONSTANTS
    -- ==========================================================================
    
    -- Customer type constants
    c_type_individual   CONSTANT VARCHAR2(20) := 'INDIVIDUAL';
    c_type_company      CONSTANT VARCHAR2(20) := 'COMPANY';
    
    -- ==========================================================================
    -- EXCEPTIONS
    -- ==========================================================================
    
    e_validation_failed EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_validation_failed, -20001);
    
    e_not_found EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_not_found, -20002);
    
    e_duplicate_customer EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_duplicate_customer, -20005);
    
    -- ==========================================================================
    -- INSERT OPERATIONS
    -- ==========================================================================
    
    -- Insert a single customer
    FUNCTION insert_customer(
        p_customer IN customer_t,
        p_user IN VARCHAR2
    ) RETURN NUMBER;
    
    -- Bulk upsert customers (insert or update)
    PROCEDURE bulk_upsert_customers(
        p_customers IN customer_tab,
        p_user IN VARCHAR2,
        p_merge_on IN VARCHAR2 DEFAULT 'CUSTOMER_CODE',
        p_metadata OUT transform_metadata_t
    );
    
    -- ==========================================================================
    -- QUERY OPERATIONS
    -- ==========================================================================
    
    -- Get customer by ID
    FUNCTION get_customer_by_id(
        p_tenant_id IN VARCHAR2,
        p_id IN NUMBER
    ) RETURN customer_t;
    
    -- Get customer by code
    FUNCTION get_customer_by_code(
        p_tenant_id IN VARCHAR2,
        p_code IN VARCHAR2
    ) RETURN customer_t;
    
    -- Get customers by filter (pipelined)
    FUNCTION get_customers_by_filter(
        p_tenant_id IN VARCHAR2,
        p_active IN NUMBER DEFAULT NULL,
        p_customer_type IN VARCHAR2 DEFAULT NULL,
        p_search_term IN VARCHAR2 DEFAULT NULL
    ) RETURN customer_tab PIPELINED;
    
    -- Count customers
    FUNCTION count_customers(
        p_tenant_id IN VARCHAR2,
        p_active IN NUMBER DEFAULT NULL
    ) RETURN NUMBER;
    
    -- ==========================================================================
    -- UPDATE OPERATIONS
    -- ==========================================================================
    
    -- Update customer
    PROCEDURE update_customer(
        p_customer IN customer_t,
        p_user IN VARCHAR2,
        p_validation OUT validation_result_t
    );
    
    -- Activate/deactivate customer
    PROCEDURE set_customer_active(
        p_tenant_id IN VARCHAR2,
        p_id IN NUMBER,
        p_active IN NUMBER,
        p_user IN VARCHAR2
    );
    
    -- ==========================================================================
    -- VALIDATION
    -- ==========================================================================
    
    -- Validate customer data
    FUNCTION validate_customer(
        p_customer IN customer_t
    ) RETURN validation_results_tab;
    
    -- Validate tax ID (CPF/CNPJ for Brazil)
    FUNCTION validate_tax_id(
        p_tax_id IN VARCHAR2,
        p_customer_type IN VARCHAR2
    ) RETURN validation_result_t;
    
    -- Validate email format
    FUNCTION validate_email(
        p_email IN VARCHAR2
    ) RETURN validation_result_t;
    
    -- ==========================================================================
    -- DATA QUALITY
    -- ==========================================================================
    
    -- Find potential duplicates
    PROCEDURE find_duplicates(
        p_tenant_id IN VARCHAR2,
        p_match_criteria IN VARCHAR2 DEFAULT 'TAX_ID',
        p_results OUT SYS_REFCURSOR
    );
    
    -- Merge duplicate customers
    PROCEDURE merge_customers(
        p_tenant_id IN VARCHAR2,
        p_keep_id IN NUMBER,
        p_merge_id IN NUMBER,
        p_user IN VARCHAR2,
        p_validation OUT validation_result_t
    );
    
END customer_pkg;
/

CREATE OR REPLACE PACKAGE BODY customer_pkg AS
    
    -- ==========================================================================
    -- PRIVATE HELPER FUNCTIONS
    -- ==========================================================================
    
    FUNCTION row_to_customer(
        p_row IN customers%ROWTYPE
    ) RETURN customer_t IS
        v_customer customer_t;
    BEGIN
        v_customer := customer_t(
            p_row.tenant_id,
            p_row.customer_code,
            p_row.name
        );
        
        v_customer.id := p_row.id;
        v_customer.customer_type := p_row.customer_type;
        v_customer.trade_name := p_row.trade_name;
        v_customer.tax_id := p_row.tax_id;
        v_customer.email := p_row.email;
        v_customer.phone := p_row.phone;
        v_customer.address_line1 := p_row.address_line1;
        v_customer.address_line2 := p_row.address_line2;
        v_customer.city := p_row.city;
        v_customer.state := p_row.state;
        v_customer.postal_code := p_row.postal_code;
        v_customer.country := p_row.country;
        v_customer.active := p_row.active;
        v_customer.notes := p_row.notes;
        v_customer.created_at := p_row.created_at;
        v_customer.updated_at := p_row.updated_at;
        v_customer.created_by := p_row.created_by;
        v_customer.updated_by := p_row.updated_by;
        
        RETURN v_customer;
    END row_to_customer;
    
    -- Validate CPF (Brazilian individual tax ID)
    FUNCTION validate_cpf(p_cpf IN VARCHAR2) RETURN BOOLEAN IS
        v_cpf VARCHAR2(11);
        v_sum NUMBER;
        v_digit NUMBER;
    BEGIN
        -- Remove non-numeric characters
        v_cpf := REGEXP_REPLACE(p_cpf, '[^0-9]', '');
        
        -- Must be 11 digits
        IF LENGTH(v_cpf) != 11 THEN
            RETURN FALSE;
        END IF;
        
        -- Check for known invalid patterns
        IF REGEXP_LIKE(v_cpf, '^(.)\1{10}$') THEN
            RETURN FALSE;
        END IF;
        
        -- First digit check
        v_sum := 0;
        FOR i IN 1..9 LOOP
            v_sum := v_sum + TO_NUMBER(SUBSTR(v_cpf, i, 1)) * (11 - i);
        END LOOP;
        v_digit := MOD(v_sum * 10, 11);
        IF v_digit = 10 THEN v_digit := 0; END IF;
        IF v_digit != TO_NUMBER(SUBSTR(v_cpf, 10, 1)) THEN
            RETURN FALSE;
        END IF;
        
        -- Second digit check
        v_sum := 0;
        FOR i IN 1..10 LOOP
            v_sum := v_sum + TO_NUMBER(SUBSTR(v_cpf, i, 1)) * (12 - i);
        END LOOP;
        v_digit := MOD(v_sum * 10, 11);
        IF v_digit = 10 THEN v_digit := 0; END IF;
        IF v_digit != TO_NUMBER(SUBSTR(v_cpf, 11, 1)) THEN
            RETURN FALSE;
        END IF;
        
        RETURN TRUE;
    END validate_cpf;
    
    -- Validate CNPJ (Brazilian company tax ID)
    FUNCTION validate_cnpj(p_cnpj IN VARCHAR2) RETURN BOOLEAN IS
        v_cnpj VARCHAR2(14);
        v_sum NUMBER;
        v_digit NUMBER;
        v_weights_1 CONSTANT VARCHAR2(12) := '543298765432';
        v_weights_2 CONSTANT VARCHAR2(13) := '6543298765432';
    BEGIN
        -- Remove non-numeric characters
        v_cnpj := REGEXP_REPLACE(p_cnpj, '[^0-9]', '');
        
        -- Must be 14 digits
        IF LENGTH(v_cnpj) != 14 THEN
            RETURN FALSE;
        END IF;
        
        -- Check for known invalid patterns
        IF REGEXP_LIKE(v_cnpj, '^(.)\1{13}$') THEN
            RETURN FALSE;
        END IF;
        
        -- First digit check
        v_sum := 0;
        FOR i IN 1..12 LOOP
            v_sum := v_sum + TO_NUMBER(SUBSTR(v_cnpj, i, 1)) * TO_NUMBER(SUBSTR(v_weights_1, i, 1));
        END LOOP;
        v_digit := MOD(v_sum, 11);
        IF v_digit < 2 THEN v_digit := 0; ELSE v_digit := 11 - v_digit; END IF;
        IF v_digit != TO_NUMBER(SUBSTR(v_cnpj, 13, 1)) THEN
            RETURN FALSE;
        END IF;
        
        -- Second digit check
        v_sum := 0;
        FOR i IN 1..13 LOOP
            v_sum := v_sum + TO_NUMBER(SUBSTR(v_cnpj, i, 1)) * TO_NUMBER(SUBSTR(v_weights_2, i, 1));
        END LOOP;
        v_digit := MOD(v_sum, 11);
        IF v_digit < 2 THEN v_digit := 0; ELSE v_digit := 11 - v_digit; END IF;
        IF v_digit != TO_NUMBER(SUBSTR(v_cnpj, 14, 1)) THEN
            RETURN FALSE;
        END IF;
        
        RETURN TRUE;
    END validate_cnpj;
    
    -- ==========================================================================
    -- INSERT OPERATIONS
    -- ==========================================================================
    
    FUNCTION insert_customer(
        p_customer IN customer_t,
        p_user IN VARCHAR2
    ) RETURN NUMBER IS
        v_id NUMBER;
        v_errors validation_results_tab;
        v_existing NUMBER;
    BEGIN
        -- Validate customer
        v_errors := validate_customer(p_customer);
        IF v_errors IS NOT NULL AND v_errors.COUNT > 0 THEN
            RAISE_APPLICATION_ERROR(-20001, 'Validation failed: ' || v_errors(1).error_message);
        END IF;
        
        -- Insert customer (relies on unique constraint on tenant_id, customer_code)
        BEGIN
            INSERT INTO customers (
                tenant_id, customer_code, customer_type, name, trade_name,
                tax_id, email, phone, address_line1, address_line2,
                city, state, postal_code, country, active, notes,
                created_at, updated_at, created_by, updated_by
            ) VALUES (
                p_customer.tenant_id,
                p_customer.customer_code,
                NVL(p_customer.customer_type, c_type_company),
                p_customer.name,
                p_customer.trade_name,
                p_customer.tax_id,
                p_customer.email,
                p_customer.phone,
                p_customer.address_line1,
                p_customer.address_line2,
            p_customer.city,
            p_customer.state,
            p_customer.postal_code,
            NVL(p_customer.country, 'BR'),
            NVL(p_customer.active, 1),
            p_customer.notes,
            SYSTIMESTAMP,
            SYSTIMESTAMP,
            p_user,
            p_user
        )
        RETURNING id INTO v_id;
        EXCEPTION
            WHEN DUP_VAL_ON_INDEX THEN
                RAISE_APPLICATION_ERROR(-20005, 'Customer code already exists: ' || p_customer.customer_code);
        END;
        
        RETURN v_id;
    END insert_customer;
    
    PROCEDURE bulk_upsert_customers(
        p_customers IN customer_tab,
        p_user IN VARCHAR2,
        p_merge_on IN VARCHAR2 DEFAULT 'CUSTOMER_CODE',
        p_metadata OUT transform_metadata_t
    ) IS
        v_existing_id NUMBER;
        v_validation validation_result_t;
    BEGIN
        p_metadata := transform_metadata_t('BULK_UPSERT');
        p_metadata.record_count := p_customers.COUNT;
        
        FOR i IN 1..p_customers.COUNT LOOP
            BEGIN
                -- Check if customer exists based on merge criteria
                IF p_merge_on = 'CUSTOMER_CODE' THEN
                    BEGIN
                        SELECT id INTO v_existing_id
                        FROM customers
                        WHERE tenant_id = p_customers(i).tenant_id
                          AND customer_code = p_customers(i).customer_code;
                    EXCEPTION
                        WHEN NO_DATA_FOUND THEN
                            v_existing_id := NULL;
                    END;
                ELSIF p_merge_on = 'TAX_ID' THEN
                    BEGIN
                        SELECT id INTO v_existing_id
                        FROM customers
                        WHERE tenant_id = p_customers(i).tenant_id
                          AND tax_id = p_customers(i).tax_id;
                    EXCEPTION
                        WHEN NO_DATA_FOUND THEN
                            v_existing_id := NULL;
                    END;
                ELSE
                    v_existing_id := NULL;
                END IF;
                
                IF v_existing_id IS NOT NULL THEN
                    -- Update existing customer
                    DECLARE
                        v_cust customer_t := p_customers(i);
                    BEGIN
                        v_cust.id := v_existing_id;
                        update_customer(v_cust, p_user, v_validation);
                        IF v_validation.is_valid = 1 THEN
                            p_metadata.success_count := p_metadata.success_count + 1;
                        ELSE
                            p_metadata.error_count := p_metadata.error_count + 1;
                        END IF;
                    END;
                ELSE
                    -- Insert new customer
                    DECLARE
                        v_id NUMBER;
                    BEGIN
                        v_id := insert_customer(p_customers(i), p_user);
                        p_metadata.success_count := p_metadata.success_count + 1;
                    END;
                END IF;
                
            EXCEPTION
                WHEN OTHERS THEN
                    p_metadata.error_count := p_metadata.error_count + 1;
                    -- Log error details for debugging
                    -- In production, consider writing to an error log table:
                    -- INSERT INTO etl_error_log (batch_id, record_index, sqlcode, sqlerrm, occurred_at)
                    -- VALUES (p_metadata.batch_id, i, SQLCODE, SQLERRM, SYSTIMESTAMP);
                    NULL; -- Continue processing remaining records
            END;
        END LOOP;
        
        p_metadata.transform_timestamp := SYSTIMESTAMP;
    END bulk_upsert_customers;
    
    -- ==========================================================================
    -- QUERY OPERATIONS
    -- ==========================================================================
    
    FUNCTION get_customer_by_id(
        p_tenant_id IN VARCHAR2,
        p_id IN NUMBER
    ) RETURN customer_t IS
        v_row customers%ROWTYPE;
    BEGIN
        SELECT * INTO v_row
        FROM customers
        WHERE tenant_id = p_tenant_id AND id = p_id;
        
        RETURN row_to_customer(v_row);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20002, 'Customer not found: ' || p_id);
    END get_customer_by_id;
    
    FUNCTION get_customer_by_code(
        p_tenant_id IN VARCHAR2,
        p_code IN VARCHAR2
    ) RETURN customer_t IS
        v_row customers%ROWTYPE;
    BEGIN
        SELECT * INTO v_row
        FROM customers
        WHERE tenant_id = p_tenant_id AND customer_code = p_code;
        
        RETURN row_to_customer(v_row);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20002, 'Customer not found: ' || p_code);
    END get_customer_by_code;
    
    FUNCTION get_customers_by_filter(
        p_tenant_id IN VARCHAR2,
        p_active IN NUMBER DEFAULT NULL,
        p_customer_type IN VARCHAR2 DEFAULT NULL,
        p_search_term IN VARCHAR2 DEFAULT NULL
    ) RETURN customer_tab PIPELINED IS
        v_row customers%ROWTYPE;
        v_search VARCHAR2(200);
    BEGIN
        v_search := '%' || UPPER(p_search_term) || '%';
        
        FOR v_row IN (
            SELECT *
            FROM customers
            WHERE tenant_id = p_tenant_id
              AND (p_active IS NULL OR active = p_active)
              AND (p_customer_type IS NULL OR customer_type = p_customer_type)
              AND (p_search_term IS NULL OR 
                   UPPER(name) LIKE v_search OR
                   UPPER(customer_code) LIKE v_search OR
                   UPPER(email) LIKE v_search OR
                   tax_id LIKE v_search)
            ORDER BY name
        ) LOOP
            PIPE ROW(row_to_customer(v_row));
        END LOOP;
        
        RETURN;
    END get_customers_by_filter;
    
    FUNCTION count_customers(
        p_tenant_id IN VARCHAR2,
        p_active IN NUMBER DEFAULT NULL
    ) RETURN NUMBER IS
        v_count NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_count
        FROM customers
        WHERE tenant_id = p_tenant_id
          AND (p_active IS NULL OR active = p_active);
          
        RETURN v_count;
    END count_customers;
    
    -- ==========================================================================
    -- UPDATE OPERATIONS
    -- ==========================================================================
    
    PROCEDURE update_customer(
        p_customer IN customer_t,
        p_user IN VARCHAR2,
        p_validation OUT validation_result_t
    ) IS
        v_errors validation_results_tab;
    BEGIN
        -- Validate
        v_errors := validate_customer(p_customer);
        IF v_errors IS NOT NULL AND v_errors.COUNT > 0 THEN
            p_validation := v_errors(1);
            RETURN;
        END IF;
        
        UPDATE customers SET
            customer_type = NVL(p_customer.customer_type, customer_type),
            name = NVL(p_customer.name, name),
            trade_name = p_customer.trade_name,
            tax_id = p_customer.tax_id,
            email = p_customer.email,
            phone = p_customer.phone,
            address_line1 = p_customer.address_line1,
            address_line2 = p_customer.address_line2,
            city = p_customer.city,
            state = p_customer.state,
            postal_code = p_customer.postal_code,
            country = p_customer.country,
            notes = p_customer.notes,
            updated_at = SYSTIMESTAMP,
            updated_by = p_user
        WHERE tenant_id = p_customer.tenant_id AND id = p_customer.id;
        
        IF SQL%ROWCOUNT = 0 THEN
            p_validation := validation_result_t(0, 'NOT_FOUND', 'Customer not found', 'id');
        ELSE
            p_validation := validation_result_t(1, NULL, NULL, NULL);
        END IF;
    END update_customer;
    
    PROCEDURE set_customer_active(
        p_tenant_id IN VARCHAR2,
        p_id IN NUMBER,
        p_active IN NUMBER,
        p_user IN VARCHAR2
    ) IS
    BEGIN
        UPDATE customers SET
            active = p_active,
            updated_at = SYSTIMESTAMP,
            updated_by = p_user
        WHERE tenant_id = p_tenant_id AND id = p_id;
        
        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20002, 'Customer not found: ' || p_id);
        END IF;
    END set_customer_active;
    
    -- ==========================================================================
    -- VALIDATION
    -- ==========================================================================
    
    FUNCTION validate_customer(
        p_customer IN customer_t
    ) RETURN validation_results_tab IS
        v_errors validation_results_tab := validation_results_tab();
        v_tax_result validation_result_t;
        v_email_result validation_result_t;
        
        PROCEDURE add_error(p_code VARCHAR2, p_message VARCHAR2, p_field VARCHAR2) IS
        BEGIN
            v_errors.EXTEND;
            v_errors(v_errors.COUNT) := validation_result_t(0, p_code, p_message, p_field);
        END;
    BEGIN
        -- Required fields
        IF p_customer.tenant_id IS NULL THEN
            add_error('REQUIRED', 'tenant_id is required', 'tenant_id');
        END IF;
        
        IF p_customer.customer_code IS NULL THEN
            add_error('REQUIRED', 'customer_code is required', 'customer_code');
        END IF;
        
        IF p_customer.name IS NULL THEN
            add_error('REQUIRED', 'name is required', 'name');
        END IF;
        
        -- Tax ID validation (if provided)
        IF p_customer.tax_id IS NOT NULL THEN
            v_tax_result := validate_tax_id(p_customer.tax_id, p_customer.customer_type);
            IF v_tax_result.is_valid = 0 THEN
                v_errors.EXTEND;
                v_errors(v_errors.COUNT) := v_tax_result;
            END IF;
        END IF;
        
        -- Email validation (if provided)
        IF p_customer.email IS NOT NULL THEN
            v_email_result := validate_email(p_customer.email);
            IF v_email_result.is_valid = 0 THEN
                v_errors.EXTEND;
                v_errors(v_errors.COUNT) := v_email_result;
            END IF;
        END IF;
        
        RETURN v_errors;
    END validate_customer;
    
    FUNCTION validate_tax_id(
        p_tax_id IN VARCHAR2,
        p_customer_type IN VARCHAR2
    ) RETURN validation_result_t IS
        v_clean_id VARCHAR2(20);
    BEGIN
        IF p_tax_id IS NULL THEN
            RETURN validation_result_t(1, NULL, NULL, NULL);
        END IF;
        
        v_clean_id := REGEXP_REPLACE(p_tax_id, '[^0-9]', '');
        
        IF p_customer_type = c_type_individual THEN
            IF NOT validate_cpf(v_clean_id) THEN
                RETURN validation_result_t(0, 'INVALID_CPF', 'Invalid CPF: ' || p_tax_id, 'tax_id');
            END IF;
        ELSIF p_customer_type = c_type_company THEN
            IF NOT validate_cnpj(v_clean_id) THEN
                RETURN validation_result_t(0, 'INVALID_CNPJ', 'Invalid CNPJ: ' || p_tax_id, 'tax_id');
            END IF;
        ELSE
            -- Try both formats
            IF LENGTH(v_clean_id) = 11 THEN
                IF NOT validate_cpf(v_clean_id) THEN
                    RETURN validation_result_t(0, 'INVALID_CPF', 'Invalid CPF: ' || p_tax_id, 'tax_id');
                END IF;
            ELSIF LENGTH(v_clean_id) = 14 THEN
                IF NOT validate_cnpj(v_clean_id) THEN
                    RETURN validation_result_t(0, 'INVALID_CNPJ', 'Invalid CNPJ: ' || p_tax_id, 'tax_id');
                END IF;
            ELSE
                RETURN validation_result_t(0, 'INVALID_TAX_ID', 'Invalid tax ID format: ' || p_tax_id, 'tax_id');
            END IF;
        END IF;
        
        RETURN validation_result_t(1, NULL, NULL, NULL);
    END validate_tax_id;
    
    FUNCTION validate_email(
        p_email IN VARCHAR2
    ) RETURN validation_result_t IS
    BEGIN
        IF p_email IS NULL THEN
            RETURN validation_result_t(1, NULL, NULL, NULL);
        END IF;
        
        -- Basic email regex validation
        IF NOT REGEXP_LIKE(p_email, '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') THEN
            RETURN validation_result_t(0, 'INVALID_EMAIL', 'Invalid email format: ' || p_email, 'email');
        END IF;
        
        RETURN validation_result_t(1, NULL, NULL, NULL);
    END validate_email;
    
    -- ==========================================================================
    -- DATA QUALITY
    -- ==========================================================================
    
    PROCEDURE find_duplicates(
        p_tenant_id IN VARCHAR2,
        p_match_criteria IN VARCHAR2 DEFAULT 'TAX_ID',
        p_results OUT SYS_REFCURSOR
    ) IS
    BEGIN
        IF p_match_criteria = 'TAX_ID' THEN
            OPEN p_results FOR
                SELECT tax_id, COUNT(*) as dup_count,
                       LISTAGG(id, ',') WITHIN GROUP (ORDER BY created_at) as customer_ids,
                       LISTAGG(name, ' | ') WITHIN GROUP (ORDER BY created_at) as names
                FROM customers
                WHERE tenant_id = p_tenant_id
                  AND tax_id IS NOT NULL
                GROUP BY tax_id
                HAVING COUNT(*) > 1
                ORDER BY dup_count DESC;
        ELSIF p_match_criteria = 'NAME' THEN
            OPEN p_results FOR
                SELECT UPPER(TRIM(name)) as normalized_name, COUNT(*) as dup_count,
                       LISTAGG(id, ',') WITHIN GROUP (ORDER BY created_at) as customer_ids
                FROM customers
                WHERE tenant_id = p_tenant_id
                GROUP BY UPPER(TRIM(name))
                HAVING COUNT(*) > 1
                ORDER BY dup_count DESC;
        ELSIF p_match_criteria = 'EMAIL' THEN
            OPEN p_results FOR
                SELECT LOWER(TRIM(email)) as normalized_email, COUNT(*) as dup_count,
                       LISTAGG(id, ',') WITHIN GROUP (ORDER BY created_at) as customer_ids
                FROM customers
                WHERE tenant_id = p_tenant_id
                  AND email IS NOT NULL
                GROUP BY LOWER(TRIM(email))
                HAVING COUNT(*) > 1
                ORDER BY dup_count DESC;
        ELSE
            RAISE_APPLICATION_ERROR(-20001, 'Invalid match criteria: ' || p_match_criteria);
        END IF;
    END find_duplicates;
    
    PROCEDURE merge_customers(
        p_tenant_id IN VARCHAR2,
        p_keep_id IN NUMBER,
        p_merge_id IN NUMBER,
        p_user IN VARCHAR2,
        p_validation OUT validation_result_t
    ) IS
        v_keep_exists NUMBER;
        v_merge_exists NUMBER;
    BEGIN
        -- Verify both customers exist
        SELECT COUNT(*) INTO v_keep_exists
        FROM customers
        WHERE tenant_id = p_tenant_id AND id = p_keep_id;
        
        SELECT COUNT(*) INTO v_merge_exists
        FROM customers
        WHERE tenant_id = p_tenant_id AND id = p_merge_id;
        
        IF v_keep_exists = 0 OR v_merge_exists = 0 THEN
            p_validation := validation_result_t(0, 'NOT_FOUND', 'One or both customers not found', 'id');
            RETURN;
        END IF;
        
        -- Update contracts to point to keep customer
        UPDATE contracts
        SET customer_id = p_keep_id, updated_at = SYSTIMESTAMP, updated_by = p_user
        WHERE tenant_id = p_tenant_id AND customer_id = p_merge_id;
        
        -- Deactivate the merged customer
        UPDATE customers
        SET active = 0, 
            notes = notes || CHR(10) || 'Merged into customer ID ' || p_keep_id || ' on ' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS'),
            updated_at = SYSTIMESTAMP, 
            updated_by = p_user
        WHERE tenant_id = p_tenant_id AND id = p_merge_id;
        
        p_validation := validation_result_t(1, NULL, NULL, NULL);
    END merge_customers;
    
END customer_pkg;
/
