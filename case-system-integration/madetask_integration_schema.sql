-- 1. Пользователи CRM (сотрудники + внешние исполнители)
CREATE TABLE users (
  id BIGSERIAL PRIMARY KEY,
  email VARCHAR(255) UNIQUE NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  full_name VARCHAR(255) NOT NULL,
  role VARCHAR(50) NOT NULL CHECK (role IN ('manager', 'accountant', 'admin', 'internal_executor', 'external_executor')),
  consent_date TIMESTAMPTZ,
  consent_ip VARCHAR(45),
  timezone VARCHAR(50) DEFAULT 'Europe/Moscow', -- Для валидации дат
  created_at TIMESTAMPTZ DEFAULT now(),
  deleted_at TIMESTAMPTZ DEFAULT NULL
);

-- 2. Исполнители (профили для MadeTask)
CREATE TABLE executors (
  id BIGSERIAL PRIMARY KEY,
  user_id BIGINT UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  external_id BIGINT UNIQUE,               -- ID из MadeTask (contractor_id)
  first_name VARCHAR(100) NOT NULL,
  last_name VARCHAR(100) NOT NULL,
  email VARCHAR(255) UNIQUE NOT NULL,
  phone VARCHAR(20) NOT NULL,
  specialization_id BIGINT NOT NULL,
  inn VARCHAR(12),
  tax_status VARCHAR(50), -- individual, self_employed, ip
  kyc_level VARCHAR(50),                   -- LVL_ONE, LVL_TWO, MISSING
  kyc_state VARCHAR(50),                   -- pending, approved, rejected, POA_EXPIRED
  is_added_to_madetask BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT now(),
  deleted_at TIMESTAMPTZ DEFAULT NULL
);

-- 3. Реквизиты исполнителей (для выплат)
CREATE TABLE requisites (
  id BIGSERIAL PRIMARY KEY,
  idempotency_key UUID UNIQUE NOT NULL,    -- Защита от дублей
  executor_id BIGINT REFERENCES executors(id) ON DELETE CASCADE,
  external_id BIGINT UNIQUE,               -- ID реквизитов из MadeTask
  method VARCHAR(50) NOT NULL CHECK (method IN ('yoomoney', 'webmoney', 'ton', 'usdt', 'bank_card')),
  details JSONB NOT NULL,                  -- {"wallet": "...", "owner": "..."} или {"card": "...", "exp": "..."}
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 4. Задачи
CREATE TABLE tasks (
  id BIGSERIAL PRIMARY KEY,
  external_id BIGINT UNIQUE,               -- task_id из MadeTask
  title TEXT NOT NULL,
  description TEXT,
  deadline DATE NOT NULL,
  idempotency_key UUID UNIQUE NOT NULL,    -- Защита от дублей,
  amount NUMERIC(14,2) NOT NULL CHECK (amount > 0),
  currency CHAR(3) NOT NULL CHECK (currency IN ('RUB','USD','EUR')),
  executor_id BIGINT REFERENCES executors(id) ON DELETE SET NULL,
  category_id BIGINT NOT NULL,
  service_id BIGINT NOT NULL,
  crm_status VARCHAR(50) NOT NULL CHECK (crm_status IN ('open', 'pending_review', 'rejected', 'accepted', 'paid')),
  madetask_status VARCHAR(50) NOT NULL,    -- opened, completed, rejected_by_customer
  version INT DEFAULT 1,                   -- Оптимистичная блокировка
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
-- Индексы для сортировки в UI (стр. 7 ТЗ)
CREATE INDEX idx_tasks_crm_status ON tasks(crm_status);
CREATE INDEX idx_tasks_deadline ON tasks(deadline);
CREATE INDEX idx_tasks_executor ON tasks(executor_id);

-- 5. Выплаты
CREATE TABLE payouts (
  id BIGSERIAL PRIMARY KEY,
  external_id BIGINT UNIQUE,               -- id выплаты из MadeTask
  task_id BIGINT REFERENCES tasks(id) ON DELETE RESTRICT, -- Нельзя удалить задачу с выплатой
  requisites_id BIGINT REFERENCES requisites(id) ON DELETE RESTRICT,
  idempotency_key UUID UNIQUE NOT NULL,    -- Защита от дублей
  amount NUMERIC(14,2) NOT NULL,
  amount_result NUMERIC(14,2),             -- Сумма к зачислению (после комиссии)
  exchange_rate NUMERIC(10,4), -- Курс на момент выплаты
  amount_rub NUMERIC(14,2),    -- Сумма в рублях для налоговой
  currency CHAR(3) NOT NULL,
  method VARCHAR(50) NOT NULL,
  status VARCHAR(50) NOT NULL CHECK (status IN ('processing', 'completed', 'canceled', 'manual_review')),
  is_manual_confirmed BOOLEAN DEFAULT FALSE,
  error_code VARCHAR(50),
  error_description TEXT,
  admin_id BIGINT REFERENCES users(id),    -- Кто подтвердил вручную
  created_at TIMESTAMPTZ DEFAULT now(),
  completed_at TIMESTAMPTZ
);

-- 6. Кэш справочников (категории, услуги)
CREATE TABLE dictionaries (
  id BIGSERIAL PRIMARY KEY,
  type VARCHAR(50) NOT NULL CHECK (type IN ('category', 'service')),
  external_id BIGINT NOT NULL,
  name VARCHAR(255) NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(type, external_id)
);

-- 7. Логи (для админа, Задача 12)
CREATE TABLE audit_logs (
  id BIGSERIAL PRIMARY KEY,
  event_type VARCHAR(50) NOT NULL,
  entity_id BIGINT,
  user_id BIGINT REFERENCES users(id),
  request_body JSONB,                      -- С маскированием PII!
  response_body JSONB,
  http_code INT,
  error_message TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 8. Индексы для фоновых задач (CRON) и архивации
-- Ускоряют выборку старых записей при очистке логов и переносе выплат в архив
CREATE INDEX idx_users_created_at ON users(created_at);
CREATE INDEX idx_executors_created_at ON executors(created_at);
CREATE INDEX idx_tasks_created_at ON tasks(created_at);
CREATE INDEX idx_payouts_created_at ON payouts(created_at);
CREATE INDEX idx_audit_logs_created_at ON audit_logs(created_at);
