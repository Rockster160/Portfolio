require "rails_helper"

# A screen only reloads onto a page the server is already serving: anything a
# booting server says instead keeps the screen where it is.
RSpec.describe "Reload preflight" do
  let(:result) { JsRunner.output("spec/javascript/reload_preflight_runner.js") }

  it "goes ahead when the server hands back the real page" do
    expect(result["shell"]).to be(true)
  end

  it "holds while the server is down or still booting" do
    expect(result["bad_gateway"]).to be(false)
    expect(result["error_page"]).to be(false)
    expect(result["refused"]).to be(false)
  end

  it "holds when the answer is some other page" do
    expect(result["login_page"]).to be(false)
  end
end
