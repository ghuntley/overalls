defmodule Marshall.Mailer.SMTPTest do
  # The shared body is Marshall.Mailer.SMTPCase (test/support/smtp_case.ex).
  @smtp_timeout_modes []
  @smtp_plain_tests true
  use Marshall.Mailer.SMTPCase
end
