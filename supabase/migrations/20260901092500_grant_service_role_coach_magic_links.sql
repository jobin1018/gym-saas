-- Grants for coach_magic_links — same minimum-privilege discipline as every
-- other grants migration (service_role has BYPASSRLS but table privileges are
-- separate; without a GRANT every query 42501s).
--
--   whatsapp-webhook (generate) -> INSERT: a new token row.
--                               -> SELECT: none needed for generation, but
--                                  granted so a future "you already have an
--                                  unexpired link" check is possible without
--                                  another migration.
--   validate-magic-link (redeem) -> SELECT: read the row to classify a
--                                   failure (not found / used / expired).
--                                -> UPDATE: stamp used_at (single-use).
--
-- NO DELETE: the rows are the audit trail for an auth-bypass mechanism and
-- are kept. A prune job for very old rows can add its own DELETE grant later.
-- anon / authenticated get nothing — RLS is on with no policy and there is no
-- browser-facing use of this table.

GRANT SELECT, INSERT, UPDATE ON public.coach_magic_links TO service_role;
