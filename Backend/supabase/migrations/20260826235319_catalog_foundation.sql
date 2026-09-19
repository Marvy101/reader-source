create schema if not exists extensions;
create extension if not exists pg_trgm with schema extensions;

create schema if not exists catalog;
create schema if not exists catalog_ingest;

revoke all on schema catalog from public, anon, authenticated;
revoke all on schema catalog_ingest from public, anon, authenticated;

comment on schema catalog is
  'Reader-owned resolved catalog entities and serving projections.';
comment on schema catalog_ingest is
  'Provider-scoped source records, reconciliation evidence, and ingest state.';

create table catalog_ingest.sources (
  id bigint generated always as identity primary key,
  code text not null unique check (code ~ '^[a-z][a-z0-9_]{1,63}$'),
  name text not null check (char_length(name) between 1 and 200),
  source_kind text not null
    check (source_kind in ('api', 'dump', 'onix_feed', 'opds_feed', 'manual')),
  base_url text,
  terms_url text,
  retention_policy text not null default 'metadata_only'
    check (
      retention_policy in (
        'metadata_only',
        'response_cache',
        'subscription_lifetime',
        'persistent'
      )
    ),
  trust_priority smallint not null default 100
    check (trust_priority between 0 and 1000),
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table catalog_ingest.ingest_runs (
  id bigint generated always as identity primary key,
  source_id bigint not null references catalog_ingest.sources(id) on delete restrict,
  cursor text,
  status text not null default 'running'
    check (status in ('running', 'completed', 'failed', 'cancelled')),
  records_seen bigint not null default 0 check (records_seen >= 0),
  records_changed bigint not null default 0 check (records_changed >= 0),
  records_failed bigint not null default 0 check (records_failed >= 0),
  error_summary text,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  check (
    (status = 'running' and completed_at is null)
    or (status <> 'running' and completed_at is not null)
  ),
  unique (id, source_id)
);

create index ingest_runs_source_started
  on catalog_ingest.ingest_runs(source_id, started_at desc);

create table catalog_ingest.source_records (
  id bigint generated always as identity primary key,
  source_id bigint not null references catalog_ingest.sources(id) on delete restrict,
  external_id text not null check (char_length(external_id) between 1 and 1000),
  record_kind text not null
    check (
      record_kind in (
        'work',
        'edition',
        'contributor',
        'publisher',
        'cover',
        'content',
        'offer'
      )
    ),
  source_updated_at timestamptz,
  payload_hash text check (payload_hash is null or payload_hash ~ '^[a-f0-9]{64}$'),
  raw_payload jsonb,
  payload_storage_path text,
  retention_expires_at timestamptz,
  last_ingest_run_id bigint,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  status text not null default 'active'
    check (status in ('active', 'deleted', 'suppressed', 'error')),
  unique (source_id, external_id),
  foreign key (last_ingest_run_id, source_id)
    references catalog_ingest.ingest_runs(id, source_id)
    on delete restrict,
  check (last_seen_at >= first_seen_at)
);

create index source_records_source_kind_seen
  on catalog_ingest.source_records(source_id, record_kind, last_seen_at desc);
create index source_records_ingest_run
  on catalog_ingest.source_records(last_ingest_run_id, source_id)
  where last_ingest_run_id is not null;
create index source_records_payload_hash
  on catalog_ingest.source_records(payload_hash)
  where payload_hash is not null;

create table catalog.work_groups (
  id bigint generated always as identity primary key,
  work_group_type text not null default 'book'
    check (
      work_group_type in (
        'book',
        'novella',
        'short_story',
        'poetry',
        'collection',
        'comic',
        'research_paper',
        'other'
      )
    ),
  state text not null default 'active'
    check (state in ('active', 'merged', 'suppressed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index work_groups_active
  on catalog.work_groups(id)
  where state = 'active';

create table catalog.works (
  id bigint generated always as identity primary key,
  work_group_id bigint not null
    references catalog.work_groups(id) on delete restrict,
  work_kind text not null default 'original'
    check (
      work_kind in ('original', 'translation', 'revision', 'abridgement', 'adaptation')
    ),
  language_code text not null default 'und'
    check (char_length(language_code) between 2 and 35),
  original_release_date date,
  state text not null default 'active'
    check (state in ('active', 'merged', 'suppressed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, work_group_id)
);

create index works_group_language_kind
  on catalog.works(work_group_id, language_code, work_kind, id);

create table catalog.work_relations (
  source_work_id bigint not null,
  work_group_id bigint not null,
  relation text not null
    check (
      relation in (
        'translation_of',
        'revision_of',
        'abridgement_of',
        'adaptation_of'
      )
    ),
  target_work_id bigint not null,
  source_record_id bigint
    references catalog_ingest.source_records(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (source_work_id, relation, target_work_id),
  foreign key (source_work_id, work_group_id)
    references catalog.works(id, work_group_id)
    on delete cascade,
  foreign key (target_work_id, work_group_id)
    references catalog.works(id, work_group_id)
    on delete restrict,
  check (source_work_id <> target_work_id)
);

create index work_relations_target
  on catalog.work_relations(target_work_id, work_group_id, relation, source_work_id);
create index work_relations_source_group
  on catalog.work_relations(source_work_id, work_group_id);
create index work_relations_source_record
  on catalog.work_relations(source_record_id)
  where source_record_id is not null;

create table catalog.work_titles (
  id bigint generated always as identity primary key,
  work_id bigint not null references catalog.works(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 1000),
  subtitle text,
  normalized_title text not null
    check (char_length(normalized_title) between 1 and 1200),
  language_code text not null default 'und'
    check (char_length(language_code) between 2 and 35),
  script_code text check (script_code is null or char_length(script_code) between 4 and 20),
  title_kind text not null default 'primary'
    check (
      title_kind in ('primary', 'original', 'alternative', 'transliterated')
    ),
  is_preferred boolean not null default false,
  source_record_id bigint
    references catalog_ingest.source_records(id) on delete set null,
  created_at timestamptz not null default now()
);

create unique index work_titles_unique_value
  on catalog.work_titles(
    work_id,
    language_code,
    title_kind,
    title,
    coalesce(subtitle, '')
  );
create unique index work_titles_one_preferred
  on catalog.work_titles(work_id, language_code)
  where is_preferred and title_kind = 'primary';
create index work_titles_work_kind
  on catalog.work_titles(work_id, title_kind, language_code);
create index work_titles_source_record
  on catalog.work_titles(source_record_id)
  where source_record_id is not null;
create index work_titles_normalized_trgm
  on catalog.work_titles using gin(normalized_title extensions.gin_trgm_ops);

create table catalog.work_descriptions (
  id bigint generated always as identity primary key,
  work_id bigint not null references catalog.works(id) on delete cascade,
  description_kind text not null default 'blurb'
    check (description_kind in ('blurb', 'summary', 'abstract')),
  language_code text not null default 'und'
    check (char_length(language_code) between 2 and 35),
  body text not null check (char_length(body) between 1 and 100000),
  is_preferred boolean not null default false,
  source_record_id bigint
    references catalog_ingest.source_records(id) on delete set null,
  created_at timestamptz not null default now()
);

create unique index work_descriptions_one_preferred
  on catalog.work_descriptions(work_id, language_code, description_kind)
  where is_preferred;
create index work_descriptions_work
  on catalog.work_descriptions(work_id, language_code, description_kind);
create index work_descriptions_source_record
  on catalog.work_descriptions(source_record_id)
  where source_record_id is not null;

create table catalog.contributors (
  id bigint generated always as identity primary key,
  contributor_kind text not null default 'person'
    check (contributor_kind in ('person', 'organization')),
  state text not null default 'active'
    check (state in ('active', 'merged', 'suppressed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table catalog.contributor_names (
  id bigint generated always as identity primary key,
  contributor_id bigint not null references catalog.contributors(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 500),
  normalized_name text not null
    check (char_length(normalized_name) between 1 and 600),
  language_code text not null default 'und'
    check (char_length(language_code) between 2 and 35),
  script_code text check (script_code is null or char_length(script_code) between 4 and 20),
  name_kind text not null default 'credited'
    check (name_kind in ('credited', 'legal', 'pen_name', 'transliterated')),
  is_preferred boolean not null default false,
  source_record_id bigint
    references catalog_ingest.source_records(id) on delete set null,
  created_at timestamptz not null default now()
);

create unique index contributor_names_unique_value
  on catalog.contributor_names(
    contributor_id,
    language_code,
    name_kind,
    name
  );
create unique index contributor_names_one_preferred
  on catalog.contributor_names(contributor_id, language_code)
  where is_preferred;
create index contributor_names_contributor
  on catalog.contributor_names(contributor_id, is_preferred desc);
create index contributor_names_source_record
  on catalog.contributor_names(source_record_id)
  where source_record_id is not null;
create index contributor_names_normalized_trgm
  on catalog.contributor_names using gin(normalized_name extensions.gin_trgm_ops);

create table catalog.work_contributions (
  work_id bigint not null references catalog.works(id) on delete cascade,
  contributor_id bigint not null references catalog.contributors(id) on delete restrict,
  role text not null
    check (
      role in (
        'author',
        'translator',
        'adapter',
        'editor',
        'illustrator',
        'other'
      )
    ),
  position integer not null default 0 check (position >= 0),
  credited_as text,
  source_record_id bigint
    references catalog_ingest.source_records(id) on delete set null,
  primary key (work_id, contributor_id, role)
);

create index work_contributions_contributor
  on catalog.work_contributions(contributor_id, role, work_id);
create index work_contributions_source_record
  on catalog.work_contributions(source_record_id)
  where source_record_id is not null;

create table catalog.publishers (
  id bigint generated always as identity primary key,
  name text not null check (char_length(name) between 1 and 500),
  normalized_name text not null
    check (char_length(normalized_name) between 1 and 600),
  publisher_kind text not null default 'publisher'
    check (publisher_kind in ('publisher', 'imprint', 'self_published')),
  parent_publisher_id bigint references catalog.publishers(id) on delete set null,
  state text not null default 'active'
    check (state in ('active', 'merged', 'suppressed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (parent_publisher_id is null or parent_publisher_id <> id)
);

create index publishers_parent
  on catalog.publishers(parent_publisher_id)
  where parent_publisher_id is not null;
create index publishers_normalized_trgm
  on catalog.publishers using gin(normalized_name extensions.gin_trgm_ops);

create table catalog.editions (
  id bigint generated always as identity primary key,
  title text not null check (char_length(title) between 1 and 1000),
  subtitle text,
  normalized_title text not null
    check (char_length(normalized_title) between 1 and 1200),
  publisher_id bigint references catalog.publishers(id) on delete set null,
  imprint_id bigint references catalog.publishers(id) on delete set null,
  edition_statement text,
  product_form text not null check (char_length(product_form) between 1 and 100),
  publication_date date,
  publication_date_precision text not null default 'unknown'
    check (publication_date_precision in ('day', 'month', 'year', 'unknown')),
  publication_country text
    check (publication_country is null or char_length(publication_country) between 2 and 3),
  language_code text not null default 'und'
    check (char_length(language_code) between 2 and 35),
  page_count integer check (page_count is null or page_count > 0),
  duration_seconds integer check (duration_seconds is null or duration_seconds > 0),
  drm_policy text not null default 'unknown'
    check (drm_policy in ('none', 'restricted', 'lcp', 'vendor', 'unknown')),
  state text not null default 'active'
    check (state in ('active', 'merged', 'suppressed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (publisher_id is null or imprint_id is null or publisher_id <> imprint_id)
);

create index editions_publisher_date
  on catalog.editions(publisher_id, publication_date desc, id)
  where publisher_id is not null;
create index editions_imprint
  on catalog.editions(imprint_id, publication_date desc, id)
  where imprint_id is not null;
create index editions_form_language_date
  on catalog.editions(product_form, language_code, publication_date desc, id);
create index editions_normalized_title_trgm
  on catalog.editions using gin(normalized_title extensions.gin_trgm_ops);

create table catalog.edition_works (
  edition_id bigint not null references catalog.editions(id) on delete cascade,
  work_id bigint not null references catalog.works(id) on delete restrict,
  role text not null default 'primary'
    check (role in ('primary', 'introduction', 'foreword', 'supplementary')),
  position integer not null default 0 check (position >= 0),
  primary key (edition_id, work_id)
);

create index edition_works_work
  on catalog.edition_works(work_id, role, edition_id);

create table catalog.edition_contributions (
  edition_id bigint not null references catalog.editions(id) on delete cascade,
  contributor_id bigint not null references catalog.contributors(id) on delete restrict,
  role text not null
    check (
      role in (
        'editor',
        'illustrator',
        'narrator',
        'cover_artist',
        'foreword',
        'other'
      )
    ),
  position integer not null default 0 check (position >= 0),
  credited_as text,
  source_record_id bigint
    references catalog_ingest.source_records(id) on delete set null,
  primary key (edition_id, contributor_id, role)
);

create index edition_contributions_contributor
  on catalog.edition_contributions(contributor_id, role, edition_id);
create index edition_contributions_source_record
  on catalog.edition_contributions(source_record_id)
  where source_record_id is not null;

create table catalog.edition_descriptions (
  id bigint generated always as identity primary key,
  edition_id bigint not null references catalog.editions(id) on delete cascade,
  description_kind text not null default 'blurb'
    check (description_kind in ('blurb', 'summary', 'abstract')),
  language_code text not null default 'und'
    check (char_length(language_code) between 2 and 35),
  body text not null check (char_length(body) between 1 and 100000),
  is_preferred boolean not null default false,
  source_record_id bigint
    references catalog_ingest.source_records(id) on delete set null,
  created_at timestamptz not null default now()
);

create unique index edition_descriptions_one_preferred
  on catalog.edition_descriptions(edition_id, language_code, description_kind)
  where is_preferred;
create index edition_descriptions_edition
  on catalog.edition_descriptions(edition_id, language_code, description_kind);
create index edition_descriptions_source_record
  on catalog.edition_descriptions(source_record_id)
  where source_record_id is not null;

create table catalog.series (
  id bigint generated always as identity primary key,
  title text not null check (char_length(title) between 1 and 1000),
  normalized_title text not null
    check (char_length(normalized_title) between 1 and 1200),
  state text not null default 'active'
    check (state in ('active', 'merged', 'suppressed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index series_normalized_title_trgm
  on catalog.series using gin(normalized_title extensions.gin_trgm_ops);

create table catalog.work_group_series (
  work_group_id bigint not null references catalog.work_groups(id) on delete cascade,
  series_id bigint not null references catalog.series(id) on delete restrict,
  position numeric(12, 4),
  position_label text,
  is_primary boolean not null default false,
  source_record_id bigint
    references catalog_ingest.source_records(id) on delete set null,
  primary key (work_group_id, series_id)
);

create index work_group_series_series
  on catalog.work_group_series(series_id, position, work_group_id);
create index work_group_series_source_record
  on catalog.work_group_series(source_record_id)
  where source_record_id is not null;

create table catalog.subjects (
  id bigint generated always as identity primary key,
  scheme text not null default 'reader',
  code text,
  label text not null check (char_length(label) between 1 and 500),
  normalized_label text not null
    check (char_length(normalized_label) between 1 and 600),
  created_at timestamptz not null default now()
);

create unique index subjects_scheme_code
  on catalog.subjects(scheme, code)
  where code is not null;
create index subjects_normalized_trgm
  on catalog.subjects using gin(normalized_label extensions.gin_trgm_ops);

create table catalog.work_group_subjects (
  work_group_id bigint not null references catalog.work_groups(id) on delete cascade,
  subject_id bigint not null references catalog.subjects(id) on delete restrict,
  weight real not null default 1 check (weight between 0 and 1),
  source_record_id bigint
    references catalog_ingest.source_records(id) on delete set null,
  primary key (work_group_id, subject_id)
);

create index work_group_subjects_subject
  on catalog.work_group_subjects(subject_id, weight desc, work_group_id);
create index work_group_subjects_source_record
  on catalog.work_group_subjects(source_record_id)
  where source_record_id is not null;

create table catalog.identifier_schemes (
  id bigint generated always as identity primary key,
  code text not null unique check (code ~ '^[a-z][a-z0-9_]{1,63}$'),
  entity_scope text not null
    check (entity_scope in ('work', 'edition', 'contributor', 'any')),
  validation_pattern text,
  created_at timestamptz not null default now()
);

insert into catalog.identifier_schemes(code, entity_scope, validation_pattern)
values
  ('isbn_13', 'edition', '^[0-9]{13}$'),
  ('isbn_10', 'edition', '^[0-9]{9}[0-9X]$'),
  ('doi', 'any', '^10\\..+$'),
  ('lccn', 'edition', null),
  ('isni', 'contributor', '^[0-9]{15}[0-9X]$'),
  ('viaf', 'contributor', '^[0-9]+$')
on conflict (code) do nothing;

create table catalog.identifiers (
  id bigint generated always as identity primary key,
  scheme_id bigint not null
    references catalog.identifier_schemes(id) on delete restrict,
  normalized_value text not null
    check (char_length(normalized_value) between 1 and 1000),
  created_at timestamptz not null default now(),
  unique (scheme_id, normalized_value)
);

create table catalog.work_identifier_claims (
  id bigint generated always as identity primary key,
  work_id bigint not null references catalog.works(id) on delete cascade,
  identifier_id bigint not null references catalog.identifiers(id) on delete restrict,
  source_record_id bigint
    references catalog_ingest.source_records(id) on delete cascade,
  raw_value text,
  status text not null default 'accepted'
    check (status in ('candidate', 'accepted', 'disputed', 'rejected')),
  confidence real not null default 1 check (confidence between 0 and 1),
  observed_at timestamptz not null default now()
);

create unique index work_identifier_claims_sourced
  on catalog.work_identifier_claims(work_id, identifier_id, source_record_id)
  where source_record_id is not null;
create unique index work_identifier_claims_manual
  on catalog.work_identifier_claims(work_id, identifier_id)
  where source_record_id is null;
create index work_identifier_claims_lookup
  on catalog.work_identifier_claims(identifier_id, confidence desc, work_id)
  where status = 'accepted';
create index work_identifier_claims_work
  on catalog.work_identifier_claims(work_id, status, identifier_id);
create index work_identifier_claims_source_record
  on catalog.work_identifier_claims(source_record_id)
  where source_record_id is not null;

create table catalog.edition_identifier_claims (
  id bigint generated always as identity primary key,
  edition_id bigint not null references catalog.editions(id) on delete cascade,
  identifier_id bigint not null references catalog.identifiers(id) on delete restrict,
  source_record_id bigint
    references catalog_ingest.source_records(id) on delete cascade,
  raw_value text,
  status text not null default 'accepted'
    check (status in ('candidate', 'accepted', 'disputed', 'rejected')),
  confidence real not null default 1 check (confidence between 0 and 1),
  observed_at timestamptz not null default now()
);

create unique index edition_identifier_claims_sourced
  on catalog.edition_identifier_claims(edition_id, identifier_id, source_record_id)
  where source_record_id is not null;
create unique index edition_identifier_claims_manual
  on catalog.edition_identifier_claims(edition_id, identifier_id)
  where source_record_id is null;
create index edition_identifier_claims_lookup
  on catalog.edition_identifier_claims(identifier_id, confidence desc, edition_id)
  where status = 'accepted';
create index edition_identifier_claims_edition
  on catalog.edition_identifier_claims(edition_id, status, identifier_id);
create index edition_identifier_claims_source_record
  on catalog.edition_identifier_claims(source_record_id)
  where source_record_id is not null;

create table catalog.work_metadata_claims (
  id bigint generated always as identity primary key,
  work_id bigint not null references catalog.works(id) on delete cascade,
  source_record_id bigint not null
    references catalog_ingest.source_records(id) on delete cascade,
  field_name text not null check (char_length(field_name) between 1 and 200),
  value jsonb not null,
  status text not null default 'candidate'
    check (status in ('candidate', 'selected', 'disputed', 'rejected')),
  confidence real not null default 0.5 check (confidence between 0 and 1),
  observed_at timestamptz not null default now(),
  unique (work_id, source_record_id, field_name)
);

create index work_metadata_claims_resolution
  on catalog.work_metadata_claims(work_id, field_name, status, confidence desc);
create index work_metadata_claims_source_record
  on catalog.work_metadata_claims(source_record_id);

create table catalog.edition_metadata_claims (
  id bigint generated always as identity primary key,
  edition_id bigint not null references catalog.editions(id) on delete cascade,
  source_record_id bigint not null
    references catalog_ingest.source_records(id) on delete cascade,
  field_name text not null check (char_length(field_name) between 1 and 200),
  value jsonb not null,
  status text not null default 'candidate'
    check (status in ('candidate', 'selected', 'disputed', 'rejected')),
  confidence real not null default 0.5 check (confidence between 0 and 1),
  observed_at timestamptz not null default now(),
  unique (edition_id, source_record_id, field_name)
);

create index edition_metadata_claims_resolution
  on catalog.edition_metadata_claims(edition_id, field_name, status, confidence desc);
create index edition_metadata_claims_source_record
  on catalog.edition_metadata_claims(source_record_id);

create table catalog.content_files (
  id bigint generated always as identity primary key,
  sha256 text not null unique check (sha256 ~ '^[a-f0-9]{64}$'),
  media_type text not null check (char_length(media_type) between 3 and 255),
  byte_size bigint not null check (byte_size > 0),
  encryption_scheme text not null default 'none'
    check (encryption_scheme in ('none', 'lcp', 'vendor', 'unknown')),
  created_at timestamptz not null default now()
);

create index content_files_media_type
  on catalog.content_files(media_type, id);

create table catalog.content_locations (
  id bigint generated always as identity primary key,
  content_file_id bigint not null references catalog.content_files(id) on delete cascade,
  source_record_id bigint
    references catalog_ingest.source_records(id) on delete set null,
  location_kind text not null
    check (location_kind in ('storage_object', 'external_url')),
  storage_bucket text,
  storage_path text,
  external_url text,
  cache_expires_at timestamptz,
  last_verified_at timestamptz,
  status text not null default 'active'
    check (status in ('active', 'stale', 'unavailable')),
  created_at timestamptz not null default now(),
  check (
    (
      location_kind = 'storage_object'
      and storage_bucket is not null
      and storage_path is not null
      and external_url is null
    )
    or
    (
      location_kind = 'external_url'
      and storage_bucket is null
      and storage_path is null
      and external_url is not null
    )
  )
);

create unique index content_locations_storage_object
  on catalog.content_locations(storage_bucket, storage_path)
  where location_kind = 'storage_object';
create unique index content_locations_external_url
  on catalog.content_locations(external_url)
  where location_kind = 'external_url';
create index content_locations_file_status
  on catalog.content_locations(content_file_id, status, last_verified_at desc);
create index content_locations_source_record
  on catalog.content_locations(source_record_id)
  where source_record_id is not null;

create table catalog.edition_files (
  edition_id bigint not null references catalog.editions(id) on delete cascade,
  content_file_id bigint not null references catalog.content_files(id) on delete restrict,
  file_role text not null default 'full_book'
    check (file_role in ('full_book', 'sample', 'supplement')),
  rights_status text not null
    check (
      rights_status in (
        'public_domain',
        'open_license',
        'publisher_authorized',
        'restricted',
        'unknown'
      )
    ),
  license_code text,
  territories text[] not null default '{}',
  source_record_id bigint
    references catalog_ingest.source_records(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (edition_id, content_file_id, file_role)
);

create index edition_files_content_file
  on catalog.edition_files(content_file_id, file_role, edition_id);
create unique index edition_files_unique_file
  on catalog.edition_files(edition_id, content_file_id);
create index edition_files_read_now
  on catalog.edition_files(edition_id, file_role, rights_status)
  where rights_status in ('public_domain', 'open_license', 'publisher_authorized');
create index edition_files_source_record
  on catalog.edition_files(source_record_id)
  where source_record_id is not null;

create table catalog.cover_images (
  id bigint generated always as identity primary key,
  sha256 text check (sha256 is null or sha256 ~ '^[a-f0-9]{64}$'),
  perceptual_hash text,
  media_type text check (media_type is null or char_length(media_type) between 3 and 255),
  width integer check (width is null or width > 0),
  height integer check (height is null or height > 0),
  byte_size bigint check (byte_size is null or byte_size > 0),
  dominant_color text,
  status text not null default 'candidate'
    check (status in ('candidate', 'verified', 'rejected')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index cover_images_sha256
  on catalog.cover_images(sha256)
  where sha256 is not null;
create index cover_images_perceptual_hash
  on catalog.cover_images(perceptual_hash)
  where perceptual_hash is not null;

create table catalog.cover_locations (
  id bigint generated always as identity primary key,
  cover_image_id bigint not null references catalog.cover_images(id) on delete cascade,
  source_record_id bigint
    references catalog_ingest.source_records(id) on delete set null,
  location_kind text not null
    check (location_kind in ('storage_object', 'external_url')),
  storage_bucket text,
  storage_path text,
  external_url text,
  cache_expires_at timestamptz,
  last_verified_at timestamptz,
  rights_status text not null default 'unknown'
    check (
      rights_status in ('licensed', 'provider_display', 'public_domain', 'unknown')
    ),
  status text not null default 'active'
    check (status in ('active', 'stale', 'unavailable')),
  created_at timestamptz not null default now(),
  check (
    (
      location_kind = 'storage_object'
      and storage_bucket is not null
      and storage_path is not null
      and external_url is null
    )
    or
    (
      location_kind = 'external_url'
      and storage_bucket is null
      and storage_path is null
      and external_url is not null
    )
  )
);

create unique index cover_locations_storage_object
  on catalog.cover_locations(storage_bucket, storage_path)
  where location_kind = 'storage_object';
create unique index cover_locations_external_url
  on catalog.cover_locations(external_url)
  where location_kind = 'external_url';
create index cover_locations_image_status
  on catalog.cover_locations(cover_image_id, status, last_verified_at desc);
create index cover_locations_source_record
  on catalog.cover_locations(source_record_id)
  where source_record_id is not null;

create table catalog.edition_covers (
  id bigint generated always as identity primary key,
  edition_id bigint not null references catalog.editions(id) on delete cascade,
  cover_image_id bigint not null references catalog.cover_images(id) on delete restrict,
  source_record_id bigint
    references catalog_ingest.source_records(id) on delete set null,
  cover_role text not null default 'front_cover'
    check (cover_role in ('front_cover', 'back_cover', 'full_cover')),
  market_code text,
  priority smallint not null default 100 check (priority between 0 and 1000),
  status text not null default 'candidate'
    check (status in ('candidate', 'selected', 'rejected')),
  created_at timestamptz not null default now()
);

create unique index edition_covers_unique_assignment
  on catalog.edition_covers(
    edition_id,
    cover_image_id,
    cover_role,
    coalesce(market_code, '')
  );
create index edition_covers_selection
  on catalog.edition_covers(edition_id, status, priority, id);
create unique index edition_covers_one_selected_market
  on catalog.edition_covers(edition_id, cover_role, coalesce(market_code, ''))
  where status = 'selected';
create index edition_covers_image
  on catalog.edition_covers(cover_image_id, edition_id);
create index edition_covers_source_record
  on catalog.edition_covers(source_record_id)
  where source_record_id is not null;

create table catalog.acquisition_offers (
  id bigint generated always as identity primary key,
  edition_id bigint not null references catalog.editions(id) on delete cascade,
  source_record_id bigint not null
    references catalog_ingest.source_records(id) on delete cascade,
  offer_kind text not null
    check (offer_kind in ('open_access', 'buy', 'borrow', 'sample', 'subscribe')),
  url text not null check (char_length(url) between 1 and 4000),
  media_type text,
  price numeric(14, 4) check (price is null or price >= 0),
  currency text check (currency is null or currency ~ '^[A-Z]{3}$'),
  territories text[] not null default '{}',
  available boolean not null default true,
  checked_at timestamptz not null default now(),
  valid_until timestamptz,
  created_at timestamptz not null default now(),
  unique (source_record_id, offer_kind, url),
  check ((price is null and currency is null) or (price is not null and currency is not null))
);

create index acquisition_offers_edition_available
  on catalog.acquisition_offers(edition_id, available, offer_kind, checked_at desc);
create index acquisition_offers_source_record
  on catalog.acquisition_offers(source_record_id);

create table catalog.work_group_presentations (
  work_group_id bigint not null references catalog.work_groups(id) on delete cascade,
  locale text not null check (char_length(locale) between 2 and 35),
  preferred_work_id bigint,
  preferred_edition_id bigint references catalog.editions(id) on delete set null,
  preferred_cover_location_id bigint
    references catalog.cover_locations(id) on delete set null,
  selection_reason text,
  updated_at timestamptz not null default now(),
  primary key (work_group_id, locale),
  foreign key (preferred_work_id, work_group_id)
    references catalog.works(id, work_group_id)
    on delete restrict,
  foreign key (preferred_edition_id, preferred_work_id)
    references catalog.edition_works(edition_id, work_id)
    on delete restrict
);

create index work_group_presentations_work
  on catalog.work_group_presentations(preferred_work_id, work_group_id)
  where preferred_work_id is not null;
create index work_group_presentations_edition
  on catalog.work_group_presentations(preferred_edition_id, preferred_work_id)
  where preferred_edition_id is not null;
create index work_group_presentations_cover
  on catalog.work_group_presentations(preferred_cover_location_id)
  where preferred_cover_location_id is not null;

create table catalog.search_documents (
  work_group_id bigint not null references catalog.work_groups(id) on delete cascade,
  locale text not null check (char_length(locale) between 2 and 35),
  display_work_id bigint,
  display_edition_id bigint references catalog.editions(id) on delete set null,
  cover_location_id bigint references catalog.cover_locations(id) on delete set null,
  display_title text not null check (char_length(display_title) between 1 and 1000),
  subtitle text,
  normalized_title text not null
    check (char_length(normalized_title) between 1 and 1200),
  alternative_titles text not null default '',
  contributor_names text not null default '',
  translator_names text not null default '',
  series_names text not null default '',
  subject_names text not null default '',
  identifier_values text not null default '',
  description text,
  release_date date,
  popularity_score bigint not null default 0 check (popularity_score >= 0),
  has_read_now boolean not null default false,
  has_ebook boolean not null default false,
  has_audiobook boolean not null default false,
  projection_version integer not null default 1 check (projection_version > 0),
  search_vector tsvector generated always as (
    setweight(to_tsvector('simple', coalesce(display_title, '')), 'A')
    || setweight(to_tsvector('simple', coalesce(alternative_titles, '')), 'A')
    || setweight(to_tsvector('simple', coalesce(contributor_names, '')), 'A')
    || setweight(to_tsvector('simple', coalesce(translator_names, '')), 'B')
    || setweight(to_tsvector('simple', coalesce(series_names, '')), 'B')
    || setweight(to_tsvector('simple', coalesce(identifier_values, '')), 'B')
    || setweight(to_tsvector('simple', coalesce(subject_names, '')), 'C')
    || setweight(to_tsvector('simple', coalesce(description, '')), 'D')
  ) stored,
  updated_at timestamptz not null default now(),
  primary key (work_group_id, locale),
  foreign key (display_work_id, work_group_id)
    references catalog.works(id, work_group_id)
    on delete restrict,
  foreign key (display_edition_id, display_work_id)
    references catalog.edition_works(edition_id, work_id)
    on delete restrict
);

create index search_documents_full_text
  on catalog.search_documents using gin(search_vector);
create index search_documents_title_trgm
  on catalog.search_documents using gin(normalized_title extensions.gin_trgm_ops);
create index search_documents_locale_title_prefix
  on catalog.search_documents(
    locale,
    normalized_title text_pattern_ops,
    popularity_score desc,
    work_group_id
  );
create index search_documents_locale_popularity
  on catalog.search_documents(locale, popularity_score desc, work_group_id);
create index search_documents_locale_release
  on catalog.search_documents(locale, release_date desc, work_group_id)
  where release_date is not null;
create index search_documents_read_now
  on catalog.search_documents(locale, popularity_score desc, work_group_id)
  where has_read_now;
create index search_documents_ebook
  on catalog.search_documents(locale, popularity_score desc, work_group_id)
  where has_ebook;
create index search_documents_audiobook
  on catalog.search_documents(locale, popularity_score desc, work_group_id)
  where has_audiobook;
create index search_documents_display_work
  on catalog.search_documents(display_work_id, work_group_id)
  where display_work_id is not null;
create index search_documents_display_edition
  on catalog.search_documents(display_edition_id, display_work_id)
  where display_edition_id is not null;
create index search_documents_cover_location
  on catalog.search_documents(cover_location_id)
  where cover_location_id is not null;

create table catalog.work_group_redirects (
  from_work_group_id bigint primary key
    references catalog.work_groups(id) on delete cascade,
  to_work_group_id bigint not null
    references catalog.work_groups(id) on delete restrict,
  reason text,
  created_at timestamptz not null default now(),
  check (from_work_group_id <> to_work_group_id)
);

create index work_group_redirects_target
  on catalog.work_group_redirects(to_work_group_id, from_work_group_id);

create table catalog.work_redirects (
  from_work_id bigint primary key references catalog.works(id) on delete cascade,
  to_work_id bigint not null references catalog.works(id) on delete restrict,
  reason text,
  created_at timestamptz not null default now(),
  check (from_work_id <> to_work_id)
);

create index work_redirects_target
  on catalog.work_redirects(to_work_id, from_work_id);

create table catalog.edition_redirects (
  from_edition_id bigint primary key references catalog.editions(id) on delete cascade,
  to_edition_id bigint not null references catalog.editions(id) on delete restrict,
  reason text,
  created_at timestamptz not null default now(),
  check (from_edition_id <> to_edition_id)
);

create index edition_redirects_target
  on catalog.edition_redirects(to_edition_id, from_edition_id);

create table catalog_ingest.source_work_matches (
  source_record_id bigint not null
    references catalog_ingest.source_records(id) on delete cascade,
  work_id bigint not null references catalog.works(id) on delete cascade,
  match_status text not null default 'candidate'
    check (match_status in ('candidate', 'accepted', 'rejected')),
  match_method text not null,
  confidence real not null check (confidence between 0 and 1),
  resolver_version integer not null check (resolver_version > 0),
  resolved_at timestamptz not null default now(),
  primary key (source_record_id, work_id)
);

create unique index source_work_matches_one_accepted
  on catalog_ingest.source_work_matches(source_record_id)
  where match_status = 'accepted';
create index source_work_matches_work
  on catalog_ingest.source_work_matches(work_id, match_status, confidence desc);

create table catalog_ingest.source_edition_matches (
  source_record_id bigint not null
    references catalog_ingest.source_records(id) on delete cascade,
  edition_id bigint not null references catalog.editions(id) on delete cascade,
  match_status text not null default 'candidate'
    check (match_status in ('candidate', 'accepted', 'rejected')),
  match_method text not null,
  confidence real not null check (confidence between 0 and 1),
  resolver_version integer not null check (resolver_version > 0),
  resolved_at timestamptz not null default now(),
  primary key (source_record_id, edition_id)
);

create unique index source_edition_matches_one_accepted
  on catalog_ingest.source_edition_matches(source_record_id)
  where match_status = 'accepted';
create index source_edition_matches_edition
  on catalog_ingest.source_edition_matches(edition_id, match_status, confidence desc);

create table catalog_ingest.source_contributor_matches (
  source_record_id bigint not null
    references catalog_ingest.source_records(id) on delete cascade,
  contributor_id bigint not null references catalog.contributors(id) on delete cascade,
  match_status text not null default 'candidate'
    check (match_status in ('candidate', 'accepted', 'rejected')),
  match_method text not null,
  confidence real not null check (confidence between 0 and 1),
  resolver_version integer not null check (resolver_version > 0),
  resolved_at timestamptz not null default now(),
  primary key (source_record_id, contributor_id)
);

create unique index source_contributor_matches_one_accepted
  on catalog_ingest.source_contributor_matches(source_record_id)
  where match_status = 'accepted';
create index source_contributor_matches_contributor
  on catalog_ingest.source_contributor_matches(
    contributor_id,
    match_status,
    confidence desc
  );

create table catalog_ingest.source_publisher_matches (
  source_record_id bigint not null
    references catalog_ingest.source_records(id) on delete cascade,
  publisher_id bigint not null references catalog.publishers(id) on delete cascade,
  match_status text not null default 'candidate'
    check (match_status in ('candidate', 'accepted', 'rejected')),
  match_method text not null,
  confidence real not null check (confidence between 0 and 1),
  resolver_version integer not null check (resolver_version > 0),
  resolved_at timestamptz not null default now(),
  primary key (source_record_id, publisher_id)
);

create unique index source_publisher_matches_one_accepted
  on catalog_ingest.source_publisher_matches(source_record_id)
  where match_status = 'accepted';
create index source_publisher_matches_publisher
  on catalog_ingest.source_publisher_matches(
    publisher_id,
    match_status,
    confidence desc
  );

create table public.library_publication_catalog_matches (
  publication_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  work_group_id bigint not null references catalog.work_groups(id) on delete restrict,
  work_id bigint,
  edition_id bigint references catalog.editions(id) on delete restrict,
  origin_content_file_id bigint
    references catalog.content_files(id) on delete restrict,
  match_level text not null
    check (match_level in ('work_group', 'work', 'edition', 'catalog_file')),
  match_method text not null
    check (
      match_method in (
        'catalog_acquisition',
        'embedded_identifier',
        'metadata_inference',
        'manual'
      )
    ),
  confidence real not null check (confidence between 0 and 1),
  evidence jsonb not null default '{}',
  matched_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (publication_id),
  unique (publication_id, user_id),
  foreign key (publication_id, user_id)
    references public.library_files(id, user_id)
    on delete cascade,
  foreign key (work_id, work_group_id)
    references catalog.works(id, work_group_id)
    on delete restrict,
  foreign key (edition_id, work_id)
    references catalog.edition_works(edition_id, work_id)
    on delete restrict,
  foreign key (edition_id, origin_content_file_id)
    references catalog.edition_files(edition_id, content_file_id)
    on delete restrict,
  check (
    (match_level = 'work_group' and work_id is null and edition_id is null and origin_content_file_id is null)
    or (match_level = 'work' and work_id is not null and edition_id is null and origin_content_file_id is null)
    or (match_level = 'edition' and work_id is not null and edition_id is not null and origin_content_file_id is null)
    or (match_level = 'catalog_file' and work_id is not null and edition_id is not null and origin_content_file_id is not null)
  ),
  check (
    match_method <> 'catalog_acquisition'
    or (match_level = 'catalog_file' and confidence = 1)
  )
);

create index library_catalog_matches_user_group
  on public.library_publication_catalog_matches(user_id, work_group_id, matched_at desc);
create index library_catalog_matches_group_analytics
  on public.library_publication_catalog_matches(
    work_group_id,
    match_level,
    matched_at desc,
    publication_id
  );
create index library_catalog_matches_work
  on public.library_publication_catalog_matches(work_id, work_group_id, matched_at desc)
  where work_id is not null;
create index library_catalog_matches_edition
  on public.library_publication_catalog_matches(edition_id, work_id, matched_at desc)
  where edition_id is not null;
create index library_catalog_matches_origin_file
  on public.library_publication_catalog_matches(
    origin_content_file_id,
    edition_id,
    matched_at desc
  )
  where origin_content_file_id is not null;
create index library_catalog_matches_edition_origin
  on public.library_publication_catalog_matches(edition_id, origin_content_file_id)
  where origin_content_file_id is not null;

create trigger catalog_sources_set_updated_at
before update on catalog_ingest.sources
for each row execute function public.set_updated_at();

create trigger catalog_work_groups_set_updated_at
before update on catalog.work_groups
for each row execute function public.set_updated_at();

create trigger catalog_works_set_updated_at
before update on catalog.works
for each row execute function public.set_updated_at();

create trigger catalog_contributors_set_updated_at
before update on catalog.contributors
for each row execute function public.set_updated_at();

create trigger catalog_publishers_set_updated_at
before update on catalog.publishers
for each row execute function public.set_updated_at();

create trigger catalog_editions_set_updated_at
before update on catalog.editions
for each row execute function public.set_updated_at();

create trigger catalog_series_set_updated_at
before update on catalog.series
for each row execute function public.set_updated_at();

create trigger catalog_cover_images_set_updated_at
before update on catalog.cover_images
for each row execute function public.set_updated_at();

create trigger catalog_search_documents_set_updated_at
before update on catalog.search_documents
for each row execute function public.set_updated_at();

create trigger library_catalog_matches_set_updated_at
before update on public.library_publication_catalog_matches
for each row execute function public.set_updated_at();

alter table catalog_ingest.sources enable row level security;
alter table catalog_ingest.ingest_runs enable row level security;
alter table catalog_ingest.source_records enable row level security;
alter table catalog_ingest.source_work_matches enable row level security;
alter table catalog_ingest.source_edition_matches enable row level security;
alter table catalog_ingest.source_contributor_matches enable row level security;
alter table catalog_ingest.source_publisher_matches enable row level security;

alter table catalog.work_groups enable row level security;
alter table catalog.works enable row level security;
alter table catalog.work_relations enable row level security;
alter table catalog.work_titles enable row level security;
alter table catalog.work_descriptions enable row level security;
alter table catalog.contributors enable row level security;
alter table catalog.contributor_names enable row level security;
alter table catalog.work_contributions enable row level security;
alter table catalog.publishers enable row level security;
alter table catalog.editions enable row level security;
alter table catalog.edition_works enable row level security;
alter table catalog.edition_contributions enable row level security;
alter table catalog.edition_descriptions enable row level security;
alter table catalog.series enable row level security;
alter table catalog.work_group_series enable row level security;
alter table catalog.subjects enable row level security;
alter table catalog.work_group_subjects enable row level security;
alter table catalog.identifier_schemes enable row level security;
alter table catalog.identifiers enable row level security;
alter table catalog.work_identifier_claims enable row level security;
alter table catalog.edition_identifier_claims enable row level security;
alter table catalog.work_metadata_claims enable row level security;
alter table catalog.edition_metadata_claims enable row level security;
alter table catalog.content_files enable row level security;
alter table catalog.content_locations enable row level security;
alter table catalog.edition_files enable row level security;
alter table catalog.cover_images enable row level security;
alter table catalog.cover_locations enable row level security;
alter table catalog.edition_covers enable row level security;
alter table catalog.acquisition_offers enable row level security;
alter table catalog.work_group_presentations enable row level security;
alter table catalog.search_documents enable row level security;
alter table catalog.work_group_redirects enable row level security;
alter table catalog.work_redirects enable row level security;
alter table catalog.edition_redirects enable row level security;

alter table public.library_publication_catalog_matches enable row level security;

revoke all on all tables in schema catalog from public, anon, authenticated;
revoke all on all sequences in schema catalog from public, anon, authenticated;
revoke all on all tables in schema catalog_ingest from public, anon, authenticated;
revoke all on all sequences in schema catalog_ingest from public, anon, authenticated;

create policy library_catalog_matches_manage_own
on public.library_publication_catalog_matches for all
to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

grant usage on schema catalog, catalog_ingest to service_role;
grant select, insert, update, delete on all tables in schema catalog to service_role;
grant select, insert, update, delete on all tables in schema catalog_ingest to service_role;
grant usage, select, update on all sequences in schema catalog to service_role;
grant usage, select, update on all sequences in schema catalog_ingest to service_role;

grant select, insert, update, delete
  on public.library_publication_catalog_matches
  to authenticated, service_role;

comment on table catalog.search_documents is
  'Denormalized, rebuildable typeahead and discovery serving projection.';
comment on table public.library_publication_catalog_matches is
  'Best-effort semantic catalog match for imports, or exact provenance for catalog acquisitions.';
