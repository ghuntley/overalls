defmodule Marshall.Mailer.SMTPStarttlsTimeoutPropertyTest do
  # The shared body is Marshall.Mailer.SMTPCase (test/support/smtp_case.ex).
  @smtp_timeout_modes [:starttls]
  @smtp_plain_tests false
  use Marshall.Mailer.SMTPCase
end
