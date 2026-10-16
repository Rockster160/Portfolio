COMMIT_SHA = Rails.root.join("REVISION").read.strip rescue "--"
# Written at deploy; a local checkout counts its own commits.
BUILD_NUMBER = (Rails.root.join("BUILD_NUMBER").read.strip rescue `git rev-list --count HEAD 2>/dev/null`.strip.presence || "--")
