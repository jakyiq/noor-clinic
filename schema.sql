-- ═══════════════════════════════════════════════
-- NOOR (نور) — Optical Clinic SaaS
-- schema.sql — Full Database Schema
-- Run this in Supabase SQL Editor
-- ═══════════════════════════════════════════════

-- ─────────────────────────────────────────────
-- EXTENSIONS
-- ─────────────────────────────────────────────
create extension if not exists "uuid-ossp";
create extension if not exists "pg_trgm"; -- for fuzzy search


-- ─────────────────────────────────────────────
-- ENUMS
-- ─────────────────────────────────────────────
create type user_role as enum ('admin', 'doctor', 'receptionist');
create type license_plan as enum ('trial', 'monthly', 'quarterly', 'yearly', 'lifetime');
create type license_status as enum ('active', 'grace', 'expired', 'suspended');
create type payment_method as enum ('cash', 'card', 'transfer');
create type payment_status as enum ('paid', 'partial', 'unpaid');
create type lens_type as enum ('single', 'bifocal', 'progressive', 'plano');
create type eye_side as enum ('right', 'left');
create type audit_action as enum (
  'login', 'logout',
  'patient_create', 'patient_update', 'patient_delete',
  'prescription_create', 'prescription_update', 'prescription_delete',
  'payment_create', 'payment_update',
  'inventory_update',
  'settings_update',
  'backup_download', 'backup_restore',
  'user_create', 'user_update', 'user_delete'
);


-- ─────────────────────────────────────────────
-- CLINICS
-- ─────────────────────────────────────────────
create table clinics (
  id                  uuid primary key default uuid_generate_v4(),
  name                text not null,
  name_ar             text,
  phone               text,
  address             text,
  address_ar          text,
  logo_url            text,
  language            text not null default 'ar' check (language in ('ar', 'en')),
  theme               text not null default 'dark' check (theme in ('dark', 'light')),
  currency            text not null default 'IQD',
  footer_text         text,        -- printed on A5 prescriptions
  footer_text_ar      text,
  next_visit_default  integer default 30, -- days
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);


-- ─────────────────────────────────────────────
-- LICENSES
-- ─────────────────────────────────────────────
create table licenses (
  id            uuid primary key default uuid_generate_v4(),
  clinic_id     uuid not null references clinics(id) on delete cascade,
  plan          license_plan not null default 'trial',
  status        license_status not null default 'active',
  started_at    timestamptz not null default now(),
  expires_at    timestamptz,        -- null = lifetime
  grace_ends_at timestamptz,        -- expires_at + 5 days
  price_paid    numeric(12,0) default 0,
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique(clinic_id)
);

-- Auto-set trial expiry and grace period
create or replace function set_license_defaults()
returns trigger language plpgsql as $$
begin
  if new.plan = 'trial' and new.expires_at is null then
    new.expires_at := new.started_at + interval '7 days';
  end if;
  if new.expires_at is not null then
    new.grace_ends_at := new.expires_at + interval '5 days';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create trigger trg_license_defaults
  before insert or update on licenses
  for each row execute function set_license_defaults();


-- ─────────────────────────────────────────────
-- CLINIC USERS  (links Supabase Auth → clinic + role)
-- ─────────────────────────────────────────────
create table clinic_users (
  id          uuid primary key default uuid_generate_v4(),
  clinic_id   uuid not null references clinics(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  role        user_role not null default 'receptionist',
  full_name   text not null,
  phone       text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique(clinic_id, user_id)
);


-- ─────────────────────────────────────────────
-- SUPERADMIN  (Abdul Rahman only)
-- ─────────────────────────────────────────────
create table superadmins (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now()
);


-- ─────────────────────────────────────────────
-- DOCTORS  (per clinic — used in prescriptions + print)
-- ─────────────────────────────────────────────
create table doctors (
  id            uuid primary key default uuid_generate_v4(),
  clinic_id     uuid not null references clinics(id) on delete cascade,
  full_name     text not null,
  full_name_ar  text,
  title         text,              -- e.g. "Dr." / "Opt."
  phone         text,
  signature_url text,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);


-- ─────────────────────────────────────────────
-- PATIENTS
-- ─────────────────────────────────────────────
create table patients (
  id            uuid primary key default uuid_generate_v4(),
  clinic_id     uuid not null references clinics(id) on delete cascade,
  full_name     text not null,
  phone         text,
  dob           date,
  gender        text check (gender in ('male', 'female', 'other')),
  address       text,
  notes         text,
  created_by    uuid references clinic_users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index idx_patients_clinic on patients(clinic_id);
create index idx_patients_name   on patients using gin (full_name gin_trgm_ops);
create index idx_patients_phone  on patients(clinic_id, phone);


-- ─────────────────────────────────────────────
-- PRESCRIPTIONS  (one per visit)
-- ─────────────────────────────────────────────
create table prescriptions (
  id              uuid primary key default uuid_generate_v4(),
  clinic_id       uuid not null references clinics(id) on delete cascade,
  patient_id      uuid not null references patients(id) on delete cascade,
  doctor_id       uuid references doctors(id),
  visit_date      date not null default current_date,

  -- Right Eye (OD)
  od_sphere       numeric(5,2),
  od_cylinder     numeric(5,2),
  od_axis         integer check (od_axis between 0 and 180),
  od_addition     numeric(4,2),
  od_va           text,     -- Visual Acuity — free text e.g. "6/6"
  od_bcva         text,     -- Best Corrected VA

  -- Left Eye (OS)
  os_sphere       numeric(5,2),
  os_cylinder     numeric(5,2),
  os_axis         integer check (os_axis between 0 and 180),
  os_addition     numeric(4,2),
  os_va           text,
  os_bcva         text,

  -- General
  ipd             numeric(4,1),   -- Inter-Pupillary Distance
  lens_type       lens_type,
  coating         text,           -- e.g. "AR", "Blue Cut", "Photochromic"
  frame_ref       text,           -- free-text frame description or SKU
  frame_id        uuid references frames(id) on delete set null,

  -- Flags
  checkup         boolean not null default false,  -- appears in follow-up list
  next_visit_date date,

  notes           text,
  created_by      uuid references clinic_users(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index idx_rx_clinic   on prescriptions(clinic_id);
create index idx_rx_patient  on prescriptions(patient_id);
create index idx_rx_date     on prescriptions(clinic_id, visit_date desc);
create index idx_rx_followup on prescriptions(clinic_id, next_visit_date)
  where checkup = true;


-- ─────────────────────────────────────────────
-- LENS INVENTORY
-- ─────────────────────────────────────────────
create table lenses (
  id            uuid primary key default uuid_generate_v4(),
  clinic_id     uuid not null references clinics(id) on delete cascade,
  brand         text,
  lens_type     lens_type not null default 'single',
  coating       text,
  material      text,             -- e.g. "CR-39", "Polycarbonate", "1.67"
  sphere        numeric(5,2) not null,
  cylinder      numeric(5,2) not null default 0,
  quantity      integer not null default 0 check (quantity >= 0),
  restock_level integer not null default 2,   -- alert when qty <= this
  cost_price    numeric(12,0) default 0,
  sell_price    numeric(12,0) default 0,
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index idx_lenses_clinic on lenses(clinic_id);
-- Index for fuzzy inventory match (±0.25 SPH + CYL)
create index idx_lenses_sph_cyl on lenses(clinic_id, sphere, cylinder);


-- ─────────────────────────────────────────────
-- FRAMES INVENTORY
-- ─────────────────────────────────────────────
create table frames (
  id            uuid primary key default uuid_generate_v4(),
  clinic_id     uuid not null references clinics(id) on delete cascade,
  brand         text,
  model         text,
  color         text,
  size          text,             -- e.g. "52-18-140"
  material      text,             -- e.g. "Metal", "Acetate"
  quantity      integer not null default 0 check (quantity >= 0),
  restock_level integer not null default 1,
  cost_price    numeric(12,0) default 0,
  sell_price    numeric(12,0) default 0,
  image_url     text,
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index idx_frames_clinic on frames(clinic_id);


-- ─────────────────────────────────────────────
-- ORDERS  (one order per prescription/sale)
-- ─────────────────────────────────────────────
create table orders (
  id                uuid primary key default uuid_generate_v4(),
  clinic_id         uuid not null references clinics(id) on delete cascade,
  patient_id        uuid not null references patients(id) on delete cascade,
  prescription_id   uuid references prescriptions(id) on delete set null,

  lens_id           uuid references lenses(id) on delete set null,
  frame_id          uuid references frames(id) on delete set null,

  lens_price        numeric(12,0) not null default 0,
  frame_price       numeric(12,0) not null default 0,
  extra_charges     numeric(12,0) not null default 0,  -- e.g. fitting fee
  discount          numeric(12,0) not null default 0,
  total_amount      numeric(12,0) not null default 0,  -- computed
  amount_paid       numeric(12,0) not null default 0,
  remaining         numeric(12,0) generated always as (total_amount - amount_paid) stored,

  payment_status    payment_status not null default 'unpaid',
  payment_method    payment_method,
  order_date        date not null default current_date,
  delivery_date     date,
  is_delivered      boolean not null default false,
  notes             text,
  created_by        uuid references clinic_users(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index idx_orders_clinic   on orders(clinic_id);
create index idx_orders_patient  on orders(patient_id);
create index idx_orders_date     on orders(clinic_id, order_date desc);
create index idx_orders_debtors  on orders(clinic_id, payment_status)
  where payment_status in ('unpaid', 'partial');


-- ─────────────────────────────────────────────
-- PAYMENTS  (multiple payments per order)
-- ─────────────────────────────────────────────
create table payments (
  id              uuid primary key default uuid_generate_v4(),
  clinic_id       uuid not null references clinics(id) on delete cascade,
  order_id        uuid not null references orders(id) on delete cascade,
  patient_id      uuid not null references patients(id) on delete cascade,
  amount          numeric(12,0) not null check (amount > 0),
  payment_method  payment_method not null default 'cash',
  payment_date    date not null default current_date,
  notes           text,
  created_by      uuid references clinic_users(id),
  created_at      timestamptz not null default now()
);

create index idx_payments_clinic on payments(clinic_id);
create index idx_payments_order  on payments(order_id);
create index idx_payments_date   on payments(clinic_id, payment_date desc);

-- Auto-update order.amount_paid + payment_status after payment insert/update/delete
create or replace function sync_order_payment()
returns trigger language plpgsql security definer as $$
declare
  v_clinic_id   uuid;
  v_order_id    uuid;
  v_total       numeric;
  v_paid        numeric;
  v_status      payment_status;
begin
  -- determine which order to update
  if tg_op = 'DELETE' then
    v_order_id  := old.order_id;
    v_clinic_id := old.clinic_id;
  else
    v_order_id  := new.order_id;
    v_clinic_id := new.clinic_id;
  end if;

  select total_amount into v_total from orders where id = v_order_id;
  select coalesce(sum(amount), 0) into v_paid from payments where order_id = v_order_id;

  if v_paid = 0 then
    v_status := 'unpaid';
  elsif v_paid >= v_total then
    v_status := 'paid';
  else
    v_status := 'partial';
  end if;

  update orders
    set amount_paid    = v_paid,
        payment_status = v_status,
        updated_at     = now()
  where id = v_order_id;

  return null;
end;
$$;

create trigger trg_sync_payment
  after insert or update or delete on payments
  for each row execute function sync_order_payment();


-- ─────────────────────────────────────────────
-- DAILY LEDGER VIEW  (computed — not a table)
-- ─────────────────────────────────────────────
create or replace view daily_ledger as
select
  p.clinic_id,
  p.payment_date                          as ledger_date,
  count(*)                                as payment_count,
  sum(p.amount)                           as total_collected,
  sum(case when p.payment_method = 'cash'     then p.amount else 0 end) as cash,
  sum(case when p.payment_method = 'card'     then p.amount else 0 end) as card,
  sum(case when p.payment_method = 'transfer' then p.amount else 0 end) as transfer
from payments p
group by p.clinic_id, p.payment_date;


-- ─────────────────────────────────────────────
-- RESTOCK ALERTS VIEW
-- ─────────────────────────────────────────────
create or replace view restock_alerts as
select
  'lens'        as item_type,
  id,
  clinic_id,
  coalesce(brand, '') || ' ' || lens_type::text || ' SPH ' || sphere::text || ' CYL ' || cylinder::text as item_name,
  quantity,
  restock_level
from lenses
where quantity <= restock_level

union all

select
  'frame'       as item_type,
  id,
  clinic_id,
  coalesce(brand, '') || ' ' || coalesce(model, '') || ' ' || coalesce(color, '') as item_name,
  quantity,
  restock_level
from frames
where quantity <= restock_level;


-- ─────────────────────────────────────────────
-- FOLLOW-UP VIEW
-- ─────────────────────────────────────────────
create or replace view followup_list as
select
  rx.clinic_id,
  rx.id               as prescription_id,
  rx.patient_id,
  p.full_name         as patient_name,
  p.phone             as patient_phone,
  rx.visit_date,
  rx.next_visit_date,
  rx.doctor_id,
  d.full_name         as doctor_name
from prescriptions rx
join patients p on p.id = rx.patient_id
left join doctors d on d.id = rx.doctor_id
where rx.checkup = true
  and rx.next_visit_date is not null;


-- ─────────────────────────────────────────────
-- AUDIT LOG
-- ─────────────────────────────────────────────
create table audit_logs (
  id          uuid primary key default uuid_generate_v4(),
  clinic_id   uuid references clinics(id) on delete set null,
  user_id     uuid references auth.users(id) on delete set null,
  action      audit_action not null,
  table_name  text,
  record_id   uuid,
  old_data    jsonb,
  new_data    jsonb,
  ip_address  text,
  user_agent  text,
  created_at  timestamptz not null default now()
);

create index idx_audit_clinic on audit_logs(clinic_id, created_at desc);
create index idx_audit_user   on audit_logs(user_id, created_at desc);


-- ─────────────────────────────────────────────
-- OFFLINE SYNC QUEUE  (used by frontend IndexedDB → Supabase)
-- ─────────────────────────────────────────────
create table sync_queue (
  id            uuid primary key default uuid_generate_v4(),
  clinic_id     uuid not null references clinics(id) on delete cascade,
  user_id       uuid references auth.users(id) on delete set null,
  operation     text not null check (operation in ('insert','update','delete')),
  table_name    text not null,
  record_id     uuid,
  payload       jsonb not null,
  synced        boolean not null default false,
  synced_at     timestamptz,
  error_msg     text,
  created_at    timestamptz not null default now()
);

create index idx_sync_unsynced on sync_queue(clinic_id, synced) where synced = false;


-- ─────────────────────────────────────────────
-- updated_at TRIGGER  (apply to all main tables)
-- ─────────────────────────────────────────────
create or replace function touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger trg_clinics_updated       before update on clinics       for each row execute function touch_updated_at();
create trigger trg_clinic_users_updated  before update on clinic_users  for each row execute function touch_updated_at();
create trigger trg_doctors_updated       before update on doctors        for each row execute function touch_updated_at();
create trigger trg_patients_updated      before update on patients       for each row execute function touch_updated_at();
create trigger trg_prescriptions_updated before update on prescriptions  for each row execute function touch_updated_at();
create trigger trg_lenses_updated        before update on lenses         for each row execute function touch_updated_at();
create trigger trg_frames_updated        before update on frames         for each row execute function touch_updated_at();
create trigger trg_orders_updated        before update on orders         for each row execute function touch_updated_at();


-- ─────────────────────────────────────────────
-- ROW LEVEL SECURITY (RLS)
-- ─────────────────────────────────────────────

-- Helper: get current user's clinic_id
create or replace function my_clinic_id()
returns uuid language sql stable security definer as $$
  select clinic_id from clinic_users
  where user_id = auth.uid() and is_active = true
  limit 1;
$$;

-- Helper: is current user a superadmin?
create or replace function is_superadmin()
returns boolean language sql stable security definer as $$
  select exists (select 1 from superadmins where user_id = auth.uid());
$$;

-- Helper: get current user's role
create or replace function my_role()
returns user_role language sql stable security definer as $$
  select role from clinic_users
  where user_id = auth.uid() and is_active = true
  limit 1;
$$;

-- Enable RLS on all tables
alter table clinics          enable row level security;
alter table licenses         enable row level security;
alter table clinic_users     enable row level security;
alter table superadmins      enable row level security;
alter table doctors          enable row level security;
alter table patients         enable row level security;
alter table prescriptions    enable row level security;
alter table lenses           enable row level security;
alter table frames           enable row level security;
alter table orders           enable row level security;
alter table payments         enable row level security;
alter table audit_logs       enable row level security;
alter table sync_queue       enable row level security;

-- ── CLINICS ──
create policy "clinic: own clinic only" on clinics
  using (id = my_clinic_id() or is_superadmin());

create policy "clinic: superadmin insert" on clinics
  for insert with check (is_superadmin());

create policy "clinic: admin update" on clinics
  for update using (id = my_clinic_id() and my_role() = 'admin');

-- ── LICENSES ──
create policy "license: own clinic" on licenses
  using (clinic_id = my_clinic_id() or is_superadmin());

-- ── CLINIC USERS ──
create policy "clinic_users: own clinic" on clinic_users
  using (clinic_id = my_clinic_id() or is_superadmin());

create policy "clinic_users: admin manage" on clinic_users
  for insert with check (clinic_id = my_clinic_id() and my_role() = 'admin');

create policy "clinic_users: admin update" on clinic_users
  for update using (clinic_id = my_clinic_id() and my_role() = 'admin');

create policy "clinic_users: admin delete" on clinic_users
  for delete using (clinic_id = my_clinic_id() and my_role() = 'admin');

-- ── SUPERADMINS ──
create policy "superadmins: self only" on superadmins
  using (user_id = auth.uid());

-- ── DOCTORS ──
create policy "doctors: own clinic" on doctors
  using (clinic_id = my_clinic_id() or is_superadmin());

create policy "doctors: admin/doctor manage" on doctors
  for insert with check (clinic_id = my_clinic_id() and my_role() in ('admin','doctor'));

create policy "doctors: admin/doctor update" on doctors
  for update using (clinic_id = my_clinic_id() and my_role() in ('admin','doctor'));

-- ── PATIENTS ──
create policy "patients: own clinic" on patients
  using (clinic_id = my_clinic_id() or is_superadmin());

create policy "patients: staff insert" on patients
  for insert with check (clinic_id = my_clinic_id());

create policy "patients: staff update" on patients
  for update using (clinic_id = my_clinic_id());

create policy "patients: admin delete" on patients
  for delete using (clinic_id = my_clinic_id() and my_role() = 'admin');

-- ── PRESCRIPTIONS ──
create policy "rx: own clinic" on prescriptions
  using (clinic_id = my_clinic_id() or is_superadmin());

create policy "rx: staff insert" on prescriptions
  for insert with check (clinic_id = my_clinic_id());

create policy "rx: doctor/admin update" on prescriptions
  for update using (clinic_id = my_clinic_id() and my_role() in ('admin','doctor'));

create policy "rx: admin delete" on prescriptions
  for delete using (clinic_id = my_clinic_id() and my_role() = 'admin');

-- ── LENSES ──
create policy "lenses: own clinic" on lenses
  using (clinic_id = my_clinic_id() or is_superadmin());

create policy "lenses: staff insert" on lenses
  for insert with check (clinic_id = my_clinic_id());

create policy "lenses: staff update" on lenses
  for update using (clinic_id = my_clinic_id());

create policy "lenses: admin delete" on lenses
  for delete using (clinic_id = my_clinic_id() and my_role() = 'admin');

-- ── FRAMES ──
create policy "frames: own clinic" on frames
  using (clinic_id = my_clinic_id() or is_superadmin());

create policy "frames: staff insert" on frames
  for insert with check (clinic_id = my_clinic_id());

create policy "frames: staff update" on frames
  for update using (clinic_id = my_clinic_id());

create policy "frames: admin delete" on frames
  for delete using (clinic_id = my_clinic_id() and my_role() = 'admin');

-- ── ORDERS ──
create policy "orders: own clinic" on orders
  using (clinic_id = my_clinic_id() or is_superadmin());

create policy "orders: staff insert" on orders
  for insert with check (clinic_id = my_clinic_id());

create policy "orders: staff update" on orders
  for update using (clinic_id = my_clinic_id());

create policy "orders: admin delete" on orders
  for delete using (clinic_id = my_clinic_id() and my_role() = 'admin');

-- ── PAYMENTS ──
create policy "payments: own clinic" on payments
  using (clinic_id = my_clinic_id() or is_superadmin());

create policy "payments: staff insert" on payments
  for insert with check (clinic_id = my_clinic_id());

create policy "payments: admin delete" on payments
  for delete using (clinic_id = my_clinic_id() and my_role() = 'admin');

-- ── AUDIT LOGS ──
create policy "audit: own clinic read" on audit_logs
  for select using (clinic_id = my_clinic_id() or is_superadmin());

create policy "audit: system insert" on audit_logs
  for insert with check (clinic_id = my_clinic_id() or is_superadmin());

-- ── SYNC QUEUE ──
create policy "sync: own clinic" on sync_queue
  using (clinic_id = my_clinic_id() or is_superadmin());

create policy "sync: own insert" on sync_queue
  for insert with check (clinic_id = my_clinic_id());


-- ─────────────────────────────────────────────
-- SIGNUP FUNCTION  (called from frontend on self-signup)
-- Creates clinic + license + clinic_user in one transaction
-- ─────────────────────────────────────────────
create or replace function create_clinic_on_signup(
  p_user_id     uuid,
  p_clinic_name text,
  p_full_name   text,
  p_phone       text default null,
  p_language    text default 'ar'
)
returns uuid language plpgsql security definer as $$
declare
  v_clinic_id uuid;
begin
  -- Create clinic
  insert into clinics (name, language, phone)
  values (p_clinic_name, p_language, p_phone)
  returning id into v_clinic_id;

  -- Create trial license
  insert into licenses (clinic_id, plan, status)
  values (v_clinic_id, 'trial', 'active');

  -- Assign user as admin
  insert into clinic_users (clinic_id, user_id, role, full_name, phone)
  values (v_clinic_id, p_user_id, 'admin', p_full_name, p_phone);

  return v_clinic_id;
end;
$$;


-- ─────────────────────────────────────────────
-- LICENSE CHECK FUNCTION  (called on every login)
-- ─────────────────────────────────────────────
create or replace function check_license(p_clinic_id uuid)
returns jsonb language plpgsql security definer as $$
declare
  v_license licenses%rowtype;
  v_now     timestamptz := now();
begin
  select * into v_license from licenses where clinic_id = p_clinic_id;

  if not found then
    return jsonb_build_object('allowed', false, 'reason', 'no_license');
  end if;

  -- Lifetime — never expires
  if v_license.plan = 'lifetime' then
    return jsonb_build_object('allowed', true, 'status', 'active', 'plan', 'lifetime');
  end if;

  -- Active within expiry
  if v_license.expires_at > v_now then
    return jsonb_build_object(
      'allowed', true,
      'status', 'active',
      'plan', v_license.plan,
      'expires_at', v_license.expires_at
    );
  end if;

  -- Within grace period
  if v_license.grace_ends_at > v_now then
    return jsonb_build_object(
      'allowed', true,
      'status', 'grace',
      'plan', v_license.plan,
      'grace_ends_at', v_license.grace_ends_at
    );
  end if;

  -- Expired
  return jsonb_build_object(
    'allowed', false,
    'reason', 'expired',
    'plan', v_license.plan,
    'expired_at', v_license.expires_at
  );
end;
$$;


-- ─────────────────────────────────────────────
-- INVENTORY MATCH FUNCTION  (fuzzy ±0.25)
-- ─────────────────────────────────────────────
create or replace function match_lens(
  p_clinic_id  uuid,
  p_sphere     numeric,
  p_cylinder   numeric,
  p_lens_type  lens_type default null
)
returns table (
  id          uuid,
  brand       text,
  lens_type   lens_type,
  coating     text,
  material    text,
  sphere      numeric,
  cylinder    numeric,
  quantity    integer,
  sell_price  numeric
) language sql stable security definer as $$
  select
    id, brand, lens_type, coating, material,
    sphere, cylinder, quantity, sell_price
  from lenses
  where clinic_id    = p_clinic_id
    and quantity     > 0
    and abs(sphere   - p_sphere)   <= 0.25
    and abs(cylinder - p_cylinder) <= 0.25
    and (p_lens_type is null or lens_type = p_lens_type)
  order by
    abs(sphere - p_sphere) + abs(cylinder - p_cylinder) asc;
$$;


-- ─────────────────────────────────────────────
-- STORAGE BUCKETS
-- ─────────────────────────────────────────────
insert into storage.buckets (id, name, public)
values
  ('clinic-logos',     'clinic-logos',     true),
  ('doctor-signatures','doctor-signatures', false),
  ('frame-images',     'frame-images',     true),
  ('backups',          'backups',          false)
on conflict do nothing;

-- Storage RLS: clinic-logos
create policy "logos: public read" on storage.objects
  for select using (bucket_id = 'clinic-logos');

create policy "logos: admin upload" on storage.objects
  for insert with check (
    bucket_id = 'clinic-logos'
    and my_role() = 'admin'
  );

-- Storage RLS: backups (admin only)
create policy "backups: admin only" on storage.objects
  for all using (
    bucket_id = 'backups'
    and my_role() = 'admin'
  );


-- ─────────────────────────────────────────────
-- SEED: Superadmin placeholder
-- Replace 'YOUR-SUPERADMIN-UUID' with Abdul Rahman's actual auth.users UUID
-- after first login, then run:
--   insert into superadmins (user_id) values ('YOUR-SUPERADMIN-UUID');
-- ─────────────────────────────────────────────


-- ═══════════════════════════════════════════════
-- END OF SCHEMA
-- ═══════════════════════════════════════════════
