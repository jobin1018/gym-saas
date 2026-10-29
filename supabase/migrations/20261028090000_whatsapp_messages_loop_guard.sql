-- whatsapp-webhook loop protection (incident 2026-10-22: JioCare auto-responder
-- ping-ponged with our bot ~30 times).
--
-- whatsapp_messages never recorded WHICH phone a row belonged to — inbound rows
-- only carried org/member (NULL for unknown senders) and the phone lived only in
-- webhook_events.payload. The per-phone reply cap needs a cheap indexed count,
-- and staff investigating a loop need to see the number, so both directions now
-- carry it.
--
--   phone             digits-only, same normalisation as members.phone
--   suppressed_reason set on an INBOUND row the bot deliberately did not answer:
--                       auto_responder | own_number | system_sender | rate_limited
--                     NULL on every normally-handled row.
--
-- Nullable, no backfill: rows from other writers (renewal reminders, owner
-- brief, welcome) don't set phone and are not part of the reply cap.

ALTER TABLE whatsapp_messages
  ADD COLUMN IF NOT EXISTS phone             TEXT,
  ADD COLUMN IF NOT EXISTS suppressed_reason TEXT
    CHECK (suppressed_reason IS NULL OR suppressed_reason IN
      ('auto_responder','own_number','system_sender','rate_limited'));

CREATE INDEX IF NOT EXISTS idx_wa_msgs_phone_dir
  ON whatsapp_messages (phone, direction, created_at)
  WHERE phone IS NOT NULL;

-- Rollback:
--   DROP INDEX IF EXISTS idx_wa_msgs_phone_dir;
--   ALTER TABLE whatsapp_messages DROP COLUMN suppressed_reason, DROP COLUMN phone;
