-- Migration 001: Create EIP Type Definitions
-- Purpose: Define type-safe data contracts for EIP integration
-- Author: GprintEx Team
-- Date: 2026-01-27

-- =============================================================================
-- VALIDATION TYPES
-- =============================================================================

-- Type for validation result
CREATE OR REPLACE TYPE validation_result_t AS OBJECT (
    is_valid NUMBER(1),
    error_code VARCHAR2(50),
    error_message VARCHAR2(4000),
    field_name VARCHAR2(100)
);
/

-- Collection type for validation results
CREATE OR REPLACE TYPE validation_results_tab AS TABLE OF validation_result_t;
/

-- =============================================================================
-- TRANSFORMATION METADATA TYPES
-- =============================================================================

-- Type for transformation metadata
CREATE OR REPLACE TYPE transform_metadata_t AS OBJECT (
    source_system VARCHAR2(100),
    transform_timestamp TIMESTAMP,
    transform_version VARCHAR2(20),
    record_count NUMBER,
    success_count NUMBER,
    error_count NUMBER,
    
    -- Constructor
    CONSTRUCTOR FUNCTION transform_metadata_t(
        p_source_system VARCHAR2 DEFAULT NULL
    ) RETURN SELF AS RESULT
);
/

CREATE OR REPLACE TYPE BODY transform_metadata_t AS
    CONSTRUCTOR FUNCTION transform_metadata_t(
        p_source_system VARCHAR2 DEFAULT NULL
    ) RETURN SELF AS RESULT IS
    BEGIN
        self.source_system := p_source_system;
        self.transform_timestamp := SYSTIMESTAMP;
        self.transform_version := '1.0';
        self.record_count := 0;
        self.success_count := 0;
        self.error_count := 0;
        RETURN;
    END;
END;
/

-- =============================================================================
-- CONTRACT TYPES
-- =============================================================================

-- Type for contract record
CREATE OR REPLACE TYPE contract_t AS OBJECT (
    id NUMBER,
    tenant_id VARCHAR2(50),
    contract_number VARCHAR2(50),
    contract_type VARCHAR2(20),
    customer_id NUMBER,
    start_date DATE,
    end_date DATE,
    duration_months NUMBER,
    auto_renew NUMBER(1),
    total_value NUMBER(15,2),
    payment_terms VARCHAR2(500),
    billing_cycle VARCHAR2(20),
    status VARCHAR2(20),
    signed_at TIMESTAMP,
    signed_by VARCHAR2(100),
    notes CLOB,
    created_at TIMESTAMP,
    updated_at TIMESTAMP,
    created_by VARCHAR2(100),
    updated_by VARCHAR2(100),
    
    -- Constructor with required fields only
    CONSTRUCTOR FUNCTION contract_t(
        p_tenant_id VARCHAR2,
        p_contract_number VARCHAR2,
        p_customer_id NUMBER,
        p_start_date DATE
    ) RETURN SELF AS RESULT,
    
    -- Validation member function
    MEMBER FUNCTION is_valid RETURN NUMBER
);
/

CREATE OR REPLACE TYPE BODY contract_t AS
    CONSTRUCTOR FUNCTION contract_t(
        p_tenant_id VARCHAR2,
        p_contract_number VARCHAR2,
        p_customer_id NUMBER,
        p_start_date DATE
    ) RETURN SELF AS RESULT IS
    BEGIN
        self.id := NULL;
        self.tenant_id := p_tenant_id;
        self.contract_number := p_contract_number;
        self.contract_type := 'SERVICE';
        self.customer_id := p_customer_id;
        self.start_date := p_start_date;
        self.end_date := NULL;
        self.duration_months := NULL;
        self.auto_renew := 0;
        self.total_value := 0;
        self.payment_terms := NULL;
        self.billing_cycle := 'MONTHLY';
        self.status := 'DRAFT';
        self.signed_at := NULL;
        self.signed_by := NULL;
        self.notes := NULL;
        self.created_at := SYSTIMESTAMP;
        self.updated_at := SYSTIMESTAMP;
        self.created_by := NULL;
        self.updated_by := NULL;
        RETURN;
    END;
    
    MEMBER FUNCTION is_valid RETURN NUMBER IS
    BEGIN
        IF self.tenant_id IS NULL THEN RETURN 0; END IF;
        IF self.contract_number IS NULL THEN RETURN 0; END IF;
        IF self.customer_id IS NULL THEN RETURN 0; END IF;
        IF self.start_date IS NULL THEN RETURN 0; END IF;
        RETURN 1;
    END;
END;
/

-- Collection type for bulk contract operations
CREATE OR REPLACE TYPE contract_tab AS TABLE OF contract_t;
/

-- =============================================================================
-- CUSTOMER TYPES
-- =============================================================================

-- Type for customer record
CREATE OR REPLACE TYPE customer_t AS OBJECT (
    id NUMBER,
    tenant_id VARCHAR2(50),
    customer_code VARCHAR2(50),
    customer_type VARCHAR2(20),
    name VARCHAR2(200),
    trade_name VARCHAR2(200),
    tax_id VARCHAR2(20),
    email VARCHAR2(200),
    phone VARCHAR2(50),
    address_line1 VARCHAR2(200),
    address_line2 VARCHAR2(200),
    city VARCHAR2(100),
    state VARCHAR2(50),
    postal_code VARCHAR2(20),
    country VARCHAR2(50),
    active NUMBER(1),
    notes CLOB,
    created_at TIMESTAMP,
    updated_at TIMESTAMP,
    created_by VARCHAR2(100),
    updated_by VARCHAR2(100),
    
    -- Constructor with required fields
    CONSTRUCTOR FUNCTION customer_t(
        p_tenant_id VARCHAR2,
        p_customer_code VARCHAR2,
        p_name VARCHAR2
    ) RETURN SELF AS RESULT,
    
    -- Validation member function
    MEMBER FUNCTION is_valid RETURN NUMBER
);
/

CREATE OR REPLACE TYPE BODY customer_t AS
    CONSTRUCTOR FUNCTION customer_t(
        p_tenant_id VARCHAR2,
        p_customer_code VARCHAR2,
        p_name VARCHAR2
    ) RETURN SELF AS RESULT IS
    BEGIN
        self.id := NULL;
        self.tenant_id := p_tenant_id;
        self.customer_code := p_customer_code;
        self.customer_type := 'COMPANY';
        self.name := p_name;
        self.trade_name := NULL;
        self.tax_id := NULL;
        self.email := NULL;
        self.phone := NULL;
        self.address_line1 := NULL;
        self.address_line2 := NULL;
        self.city := NULL;
        self.state := NULL;
        self.postal_code := NULL;
        self.country := NULL;
        self.active := 1;
        self.notes := NULL;
        self.created_at := SYSTIMESTAMP;
        self.updated_at := SYSTIMESTAMP;
        self.created_by := NULL;
        self.updated_by := NULL;
        RETURN;
    END;
    
    MEMBER FUNCTION is_valid RETURN NUMBER IS
    BEGIN
        IF self.tenant_id IS NULL THEN RETURN 0; END IF;
        IF self.customer_code IS NULL THEN RETURN 0; END IF;
        IF self.name IS NULL THEN RETURN 0; END IF;
        RETURN 1;
    END;
END;
/

-- Collection type for bulk customer operations
CREATE OR REPLACE TYPE customer_tab AS TABLE OF customer_t;
/

-- =============================================================================
-- ETL SESSION TYPES
-- =============================================================================

-- Type for ETL staging record
CREATE OR REPLACE TYPE etl_staging_row_t AS OBJECT (
    session_id VARCHAR2(100),
    seq_num NUMBER,
    entity_type VARCHAR2(50),
    source_system VARCHAR2(100),
    raw_data CLOB,
    transformed_data CLOB,
    status VARCHAR2(20),
    error_message VARCHAR2(4000),
    created_at TIMESTAMP,
    processed_at TIMESTAMP
);
/

-- Collection type for staging rows
CREATE OR REPLACE TYPE etl_staging_tab AS TABLE OF etl_staging_row_t;
/

-- =============================================================================
-- MESSAGE TYPES
-- =============================================================================

-- Type for integration messages
CREATE OR REPLACE TYPE integration_message_t AS OBJECT (
    message_id VARCHAR2(100),
    correlation_id VARCHAR2(100),
    message_type VARCHAR2(50),
    source_system VARCHAR2(100),
    routing_key VARCHAR2(200),
    payload CLOB,
    status VARCHAR2(20),
    created_at TIMESTAMP,
    processed_at TIMESTAMP,
    retry_count NUMBER,
    error_message VARCHAR2(4000)
);
/

-- Collection type for messages
CREATE OR REPLACE TYPE integration_message_tab AS TABLE OF integration_message_t;
/

-- End of migration 001
