require "rails_helper"

# The Mini's dashboard hears that what it shows of the owner moved: the Claude usage the
# status line reports, a build, a production script.
RSpec.describe MiniDashboardChannel, type: :channel do
  let(:user) { User.me }
  let(:stream) { described_class.broadcasting_for(user) }

  it "follows the owner, and says so when the Claude usage, a build or a script moves" do
    stub_connection(current_user: user)
    subscribe
    expect(subscription).to have_stream_for(user)

    expect { user.caches.set(:claude_usage, { seven_day: { used: 83 } }.to_json) }.to have_broadcasted_to(stream).at_least(:once).with(type: "changed")
    expect { user.caches.set(:battery, { phone: 40 }) }.not_to have_broadcasted_to(stream)

    build = nil
    expect { build = FeatureBuild.create!(user: user, title: "Bigger icons", request: "Bigger icons", status: :running) }.to have_broadcasted_to(stream)
    expect { build.update!(pr_number: 41) }.to have_broadcasted_to(stream)
    script = ProductionScript.create!(user: user, title: "Add the yell", code: "1", commit_sha: "abc1234", edited_by: :mini)
    expect { script.update!(status: :succeeded) }.to have_broadcasted_to(stream)
  end
end
