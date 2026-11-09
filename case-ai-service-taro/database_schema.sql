-- Расширения
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 1. ENUM типы
CREATE TYPE generation_status_enum AS ENUM (
    'AWAITING_PAYMENT', 'PAYMENT_PENDING', 
    'QUEUED', 'PROCESSING', 'RETRY_WAIT', 
    'COMPLETED', 'FAILED', 'FAILED_VALIDATION', 'CANCELED'
);
CREATE TYPE payment_status_enum AS ENUM ('pending', 'succeeded', 'canceled', 'refunded');
CREATE TYPE receipt_status_enum AS ENUM ('created', 'failed', 'annulled', 'not_required');
CREATE TYPE ticket_status_enum AS ENUM ('NEW', 'IN_PROGRESS', 'RESOLVED');
CREATE TYPE deletion_status_enum AS ENUM ('PENDING', 'COMPLETED', 'REJECTED');

-- ==========================================
-- 2. АДМИНИСТРАТОРЫ И БЕЗОПАСНОСТЬ
-- ==========================================

CREATE TABLE admin_users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    totp_secret VARCHAR(255),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE admin_sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    admin_id UUID NOT NULL REFERENCES admin_users(id) ON DELETE CASCADE,
    token_hash VARCHAR(255) NOT NULL,
    csrf_token VARCHAR(255) NOT NULL, -- M-09
    expires_at TIMESTAMPTZ NOT NULL,
    ip_address VARCHAR(45),
    user_agent TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE password_reset_tokens (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    admin_id UUID NOT NULL REFERENCES admin_users(id) ON DELETE CASCADE,
    token_hash VARCHAR(255) NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    is_used BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE 2fa_backup_codes (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    admin_id UUID NOT NULL REFERENCES admin_users(id) ON DELETE CASCADE,
    code_hash VARCHAR(255) NOT NULL,
    is_used BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ==========================================
-- 3. ПОЛЬЗОВАТЕЛИ И КОНТЕНТ
-- ==========================================

CREATE TABLE anonymous_visitors (
    visitor_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    fingerprint VARCHAR(255),
    fingerprint_updated_at TIMESTAMPTZ, -- M-06
    free_interpretation_used BOOLEAN NOT NULL DEFAULT FALSE,
    free_interpretation_pending BOOLEAN NOT NULL DEFAULT FALSE, -- C-02
    free_interpretation_pending_since TIMESTAMPTZ, -- C-02
    cookie_consent_given BOOLEAN NOT NULL DEFAULT FALSE,
    consent_at TIMESTAMPTZ,
    first_visit_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_visit_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE decks (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL,
    author VARCHAR(255) NOT NULL,
    type VARCHAR(50) NOT NULL,
    max_cards INT NOT NULL DEFAULT 78,
    allow_reversed BOOLEAN NOT NULL DEFAULT FALSE,
    suits JSONB,
    description TEXT NOT NULL,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX idx_decks_name_active ON decks(name) WHERE is_deleted = false; -- C-07

CREATE TABLE cards (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    deck_id UUID NOT NULL REFERENCES decks(id) ON DELETE RESTRICT,
    name VARCHAR(255) NOT NULL,
    suit VARCHAR(255),
    short_description TEXT NOT NULL,
    full_description TEXT NOT NULL,
    number INT,
    reversed_short_description TEXT,
    reversed_full_description TEXT,
    image_url_thumb VARCHAR(500),
    image_url_medium VARCHAR(500),
    image_url_original VARCHAR(500),
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
-- Частичные уникальные индексы для карт (C-07)
CREATE UNIQUE INDEX idx_cards_name_active ON cards(deck_id, name) WHERE is_deleted = false;
CREATE UNIQUE INDEX idx_cards_number_active ON cards(deck_id, number) WHERE is_deleted = false AND number IS NOT NULL;

CREATE TABLE spreads (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL,
    description TEXT NOT NULL,
    amount INT NOT NULL,
    positions JSONB NOT NULL,
    info TEXT,
    tags JSONB NOT NULL, -- M-03 (массив объектов normalized/display)
    image_url VARCHAR(500) NOT NULL,
    favorite_deck_ids JSONB,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX idx_spreads_name_active ON spreads(name) WHERE is_deleted = false; -- C-07
CREATE INDEX idx_spreads_tags_gin ON spreads USING GIN (tags); -- M-03

-- ==========================================
-- 4. ГЕНЕРАЦИЯ И ПЛАТЕЖИ
-- ==========================================

CREATE TABLE generated_spreads (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    visitor_id UUID NOT NULL REFERENCES anonymous_visitors(visitor_id) ON DELETE RESTRICT,
    spread_id UUID NOT NULL REFERENCES spreads(id) ON DELETE RESTRICT,
    deck_id UUID NOT NULL REFERENCES decks(id) ON DELETE RESTRICT,
    cards_snapshot JSONB NOT NULL,
    generation_status generation_status_enum NOT NULL DEFAULT 'AWAITING_PAYMENT',
    is_free_request BOOLEAN NOT NULL DEFAULT FALSE,
    email VARCHAR(255),
    email_consent_at TIMESTAMPTZ,
    user_context TEXT,
    interpretation_requested_at TIMESTAMPTZ,
    interpretation_text TEXT,
    tokens_input INT,
    tokens_output INT,
    error_code VARCHAR(50),
    is_viewed BOOLEAN NOT NULL DEFAULT FALSE,
    email_delivered BOOLEAN NOT NULL DEFAULT FALSE,
    email_delete_after TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    cancel_reason VARCHAR(50) NULL
);
CREATE INDEX idx_generated_spreads_status ON generated_spreads(generation_status);

CREATE TABLE payments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    generated_spread_id UUID NOT NULL REFERENCES generated_spreads(id) ON DELETE RESTRICT,
    visitor_id UUID NOT NULL REFERENCES anonymous_visitors(visitor_id) ON DELETE RESTRICT,
    yookassa_id VARCHAR(255) UNIQUE NOT NULL,
    amount NUMERIC(10, 2) NOT NULL CHECK (amount > 0),
    status payment_status_enum NOT NULL DEFAULT 'pending',
    email VARCHAR(255) NOT NULL, -- Добавлено для 422-ФЗ
    possible_duplicate_payment BOOLEAN NOT NULL DEFAULT FALSE,
    offer_agreed_at TIMESTAMPTZ,
    offer_version VARCHAR(20),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_payments_visitor_id ON payments(visitor_id);
CREATE INDEX idx_payments_status ON payments(status);

CREATE TABLE receipt_jobs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    payment_id UUID NOT NULL UNIQUE REFERENCES payments(id) ON DELETE RESTRICT,
    provider VARCHAR(50) NOT NULL,
    status receipt_status_enum NOT NULL DEFAULT 'created',
    email VARCHAR(255) NOT NULL, -- Добавлено для гарантированной отправки чека
    external_receipt_id VARCHAR(255),
    attempts INT NOT NULL DEFAULT 0,
    last_error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE interpretation_prices (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    amount NUMERIC(10, 2) NOT NULL CHECK (amount > 0),
    admin_id UUID NOT NULL REFERENCES admin_users(id) ON DELETE RESTRICT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ==========================================
-- 5. КОНТЕНТ, ПОДДЕРЖКА И ЮРИДИЧЕСКИЕ ДОКУМЕНТЫ
-- ==========================================

CREATE TABLE prompt_versions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    text TEXT NOT NULL,
    admin_id UUID NOT NULL REFERENCES admin_users(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE about_page_content (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    content_blocks JSONB NOT NULL,
    faq JSONB NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE legal_documents (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    slug VARCHAR(50) NOT NULL,
    title VARCHAR(255) NOT NULL,
    content TEXT NOT NULL,
    version VARCHAR(20) NOT NULL DEFAULT '1.0',
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Частичный уникальный индекс: только одна активная версия на документ
CREATE UNIQUE INDEX idx_legal_docs_active_slug ON legal_documents(slug) WHERE is_active = TRUE;

CREATE TABLE support_tickets (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    visitor_id UUID REFERENCES anonymous_visitors(visitor_id) ON DELETE SET NULL,
    name VARCHAR(255),
    email VARCHAR(255),
    contact_channel VARCHAR(50) NOT NULL,
    telegram_username VARCHAR(255),
    subject VARCHAR(255),
    message TEXT NOT NULL,
    status ticket_status_enum NOT NULL DEFAULT 'NEW',
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE, -- M-07
    deleted_at TIMESTAMPTZ,                    -- M-07
    deleted_by UUID REFERENCES admin_users(id) ON DELETE SET NULL, -- M-07
    email_delete_after TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE support_ticket_comments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ticket_id UUID NOT NULL REFERENCES support_tickets(id) ON DELETE CASCADE,
    admin_id UUID NOT NULL REFERENCES admin_users(id) ON DELETE RESTRICT,
    text TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE data_deletion_requests (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    visitor_id UUID REFERENCES anonymous_visitors(visitor_id) ON DELETE SET NULL,
    email VARCHAR(255), -- M-08 (зануляется)
    email_hash VARCHAR(255) NOT NULL, -- M-08 (хранится)
    status deletion_status_enum NOT NULL DEFAULT 'PENDING',
    rejection_reason TEXT, -- M-08
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processed_at TIMESTAMPTZ
);

-- ==========================================
-- 6. СИСТЕМНЫЕ ТАБЛИЦЫ И АНАЛИТИКА
-- ==========================================

CREATE TABLE outbox_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    event_type VARCHAR(100) NOT NULL,
    payload JSONB NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    retry_count INT NOT NULL DEFAULT 0,
    last_error TEXT,
    celery_task_id VARCHAR(255),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    next_retry_at TIMESTAMPTZ,
    processed_at TIMESTAMPTZ
);
CREATE INDEX idx_outbox_pending ON outbox_events(created_at) WHERE status = 'PENDING';

CREATE TABLE analytics_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    visitor_id UUID REFERENCES anonymous_visitors(visitor_id) ON DELETE SET NULL,
    event_type VARCHAR(50) NOT NULL,
    deck_id UUID REFERENCES decks(id) ON DELETE SET NULL,
    spread_id UUID REFERENCES spreads(id) ON DELETE SET NULL,
    generated_spread_id UUID REFERENCES generated_spreads(id) ON DELETE SET NULL,
    amount NUMERIC(10, 2),
    metadata JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
) PARTITION BY RANGE (created_at);

CREATE INDEX idx_analytics_event_type ON analytics_events(event_type, created_at);
CREATE INDEX idx_analytics_visitor ON analytics_events(visitor_id, created_at);
CREATE INDEX idx_support_tickets_active ON support_tickets(status, created_at) WHERE is_deleted = false;
CREATE INDEX idx_outbox_failed ON outbox_events(created_at) WHERE status = 'FAILED';

-- Примечание: Таблица logs создается с партиционированием по timestamp.
-- В рамках данного DDL она опущена для краткости, так как ее структура 
-- описана в разделе "Модель данных" и требует ручного создания партиций.
