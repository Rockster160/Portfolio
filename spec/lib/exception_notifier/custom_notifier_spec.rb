require "rails_helper"
require Rails.root.join("lib/custom_notifier").to_s

# A request that raised, in the error log by the action it reached.
RSpec.describe ExceptionNotifier::CustomNotifier do
  let(:user) { User.me }

  before { allow(SlackNotifier).to receive(:puts) }

  def request_failure(path, params: {})
    exception = ActiveRecord::RecordInvalid.new.tap { |e|
      allow(e).to receive(:message).and_return("Validation failed: Slug has already been taken")
      e.set_backtrace([Rails.root.join("app/controllers/timer_pages_controller.rb:20").to_s])
    }
    kontroller = instance_double(ApplicationController, controller_name: "timer_pages", action_name: "create")
    env = Rack::MockRequest.env_for(path, method: "POST").merge(
      "action_controller.instance"        => kontroller,
      "exception_notifier.exception_data" => { current_user: user, params: params },
    )
    env["action_dispatch.request"] = ActionDispatch::Request.new(env)
    described_class.new({}).call(exception, env: env)
  end

  it "records it by the action, the path and who it happened for" do
    request_failure("/timers/pages?x=1", params: { "tab_id" => "4bf998f9" })

    row = ErrorReport.last
    expect(row.section).to eq("timer_pages#create")
    expect(row.message).to eq("POST /timers/pages\nValidation failed: Slug has already been taken")
    expect(row.user_id).to eq(user.id)
    expect(row).to have_attributes(layer: "backend", tag: "request")
  end

  # The params ride in the alert, not in what it is grouped by.
  it "groups the same failure with different params as one" do
    request_failure("/timers/pages", params: { "tab_id" => "4bf998f9" })
    request_failure("/timers/pages", params: { "tab_id" => "fe2487c0", "meta" => {} })

    expect(ErrorReport.distinct.count(:fingerprint)).to eq(1)
  end
end
