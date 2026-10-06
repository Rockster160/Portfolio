require "rails_helper"
require "open3"

# Production compresses every stylesheet with SassC on deploy, re-parsing the
# compiled CSS. A sheet that compiles fine in development can still abort
# `assets:precompile` there, so each one is put through that second pass here.
RSpec.describe "Stylesheet compression" do
  it "compresses every precompiled stylesheet the way production does" do
    runner = Rails.root.join("spec/assets/stylesheet_compress_runner.rb").to_s
    out, err, status = Open3.capture3("bundle", "exec", "ruby", runner)
    expect(status).to be_success, err

    result = JSON.parse(out.lines.last)
    expect(result["checked"]).to be > 0
    expect(result["failures"]).to eq({})
  end
end
