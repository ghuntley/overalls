defmodule Marshall.Mailer.SMTPImplicitTimeoutPropertyTest do
  # The shared body is Marshall.Mailer.SMTPCase (test/support/smtp_case.ex).
  @smtp_timeout_modes [:implicit]
  @smtp_plain_tests false
  use Marshall.Mailer.SMTPCase
end
