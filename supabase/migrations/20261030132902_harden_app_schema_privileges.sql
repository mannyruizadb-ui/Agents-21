-- Sprint Zero review (architect N3, security L1): least privilege on schema app.
-- Displays use authenticated device accounts, so anon never needs the helper schema.
revoke usage on schema app from anon;

-- Functions get EXECUTE for PUBLIC by default. Helpers and RPCs created later in app must
-- be granted explicitly, per function, to the roles that need them.
alter default privileges in schema app revoke execute on functions from public;
