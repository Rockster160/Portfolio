# `Time.zone=` writes a thread-local that outlives the example that set it, so
# one spec switching zones silently rezones every file that runs after it in the
# same process. That's invisible under the default (alphabetical, stable) order
# and shows up as unrelated date-boundary failures under `--order random`.
#
# Put it back after every example. Cheap, and it means a spec that needs a
# different zone can just set one without also having to remember to clean up.
RSpec.configure do |config|
  config.around do |example|
    # `use_zone` restores whatever was set before the block, so an assignment
    # made inside the example is unwound on the way out.
    Time.use_zone(Rails.application.config.time_zone) { example.run }
  end
end
