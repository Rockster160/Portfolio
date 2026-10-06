# Configures ActiveRecord::Encryption for any model that calls
# `encrypts :col`. Keys come from ENV so we don't depend on Rails
# credentials infrastructure that isn't set up here.
#
# To generate fresh keys (once, then put the output values into prod env):
#
#   $ bin/rails db:encryption:init
#
# That prints the three values below as YAML — copy each into:
#
#   PORTFOLIO_AR_ENCRYPTION_PRIMARY_KEY
#   PORTFOLIO_AR_ENCRYPTION_DETERMINISTIC_KEY
#   PORTFOLIO_AR_ENCRYPTION_KEY_DERIVATION_SALT
#
# Once they're set + the app restarts, any model with `encrypts :col`
# starts encrypting new writes. `support_unencrypted_data = true` keeps
# legacy plain-text rows readable during the transition; flip it to
# false after a one-time re-save sweep
# (lib/scripts/encrypt_google_account_tokens.rb).

#
# The test environment gets fixed throwaway keys so a spec can write an
# encrypted column without the real ones.

test_key = ->(name) { Rails.env.test? ? "test-#{name}-key-not-a-secret" : nil }

Rails.application.config.active_record.encryption.tap { |enc|
  enc.primary_key = ENV["PORTFOLIO_AR_ENCRYPTION_PRIMARY_KEY"].presence || test_key[:primary]
  enc.deterministic_key = ENV["PORTFOLIO_AR_ENCRYPTION_DETERMINISTIC_KEY"].presence || test_key[:deterministic]
  enc.key_derivation_salt = ENV["PORTFOLIO_AR_ENCRYPTION_KEY_DERIVATION_SALT"].presence || test_key[:salt]
  enc.support_unencrypted_data = true
}
