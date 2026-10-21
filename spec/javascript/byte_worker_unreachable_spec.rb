require "rails_helper"

# A board opened with nothing cached while the server can't be reached (mid
# deploy, wifi gone) gets a page that keeps trying, not the browser's own error,
# which a wall screen would sit on until somebody reloaded it.
RSpec.describe "Byte worker with no server and no cache" do
  let(:result) { JsRunner.output("spec/javascript/byte_worker_unreachable_runner.js") }

  it "answers with a page that says so and tries again" do
    expect(result).to include("status" => 503, "says" => true, "retries" => true)
    expect(result["type"]).to start_with("text/html")
  end
end
