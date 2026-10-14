-- Reuse the existing authenticated send-fcm dispatch configuration.
-- The prior driver-only credential was not a JWT and every driver batch failed
-- at the Edge Function gateway before a queue row could be claimed.
update public.driver_notification_dispatch_config as driver
set
  function_url = cashier.function_url,
  function_auth_token = cashier.function_auth_token,
  updated_at = now()
from public.cashier_fcm_dispatch_config as cashier
where driver.is_enabled = true
  and coalesce(cashier.is_enabled, true) = true;
