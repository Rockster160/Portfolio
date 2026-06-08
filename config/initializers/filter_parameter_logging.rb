# Be sure to restart your server when you modify this file.

# Configure sensitive parameters which will be filtered from the log file.
Rails.application.config.filter_parameters += [
  :password, :secret, :token, :api_key, :crypt, :salt, :certificate, :otp, :ssn,
  # Not sensitive — just noisy. A 10-50 KB base64 blob per request would
  # drown out everything else in the log. ChoreGoal#image_url is the
  # same story: user-uploaded data URLs that bury the surrounding fields
  # in console output.
  :image_data, :image_url
]

# Same for ActiveRecord inspect output — `HouseholdIcon.last` in the
# console should show `image_data: [FILTERED]`, not the full data URL.
Rails.application.config.to_prepare {
  ActiveRecord::Base.filter_attributes += [:image_data, :image_url]
}
