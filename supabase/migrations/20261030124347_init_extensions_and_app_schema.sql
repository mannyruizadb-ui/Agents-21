-- Sprint Zero: foundations only. Tables arrive in Milestone 1 (PRD §4).
create extension if not exists pgcrypto with schema extensions;
create extension if not exists btree_gist with schema extensions;

-- Enums and helper functions live in schema `app` (.claude/rules/database.md).
create schema if not exists app;
grant usage on schema app to authenticated, anon, service_role;

comment on schema app is 'PlantBoard enums and helper functions (RLS helpers, conversions).';
