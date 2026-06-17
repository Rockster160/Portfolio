require "rails_helper"

# Pins the defensive nil-check on `RestClient::ExceptionWithResponse#response`
# inside `TeslaControl#tesla_exc_code`. Some failure modes (connection
# reset, DNS, timeout-without-response) raise the response-bearing
# exception class with `response == nil` — calling `.code` on nil leaks
# `NoMethodError` into the worker exception report instead of the
# wakeup_retry's intentional `else` branch.
RSpec.describe TeslaControl do
  let(:control) { TeslaControl.new(User.me) }

  describe "#tesla_exc_code (private)" do
    it "returns 500 when the exception's response is nil" do
      exc = RestClient::ServerBrokeConnection.new(nil)
      expect(exc.response).to be_nil
      expect(control.send(:tesla_exc_code, exc)).to eq(500)
    end

    it "returns the exception's status code when response is present and non-500" do
      response = instance_double("RestClient::Response", code: 401)
      exc = instance_double("RestClient::ExceptionWithResponse", response: response)
      expect(control.send(:tesla_exc_code, exc)).to eq(401)
    end
  end

  describe "#wakeup_retry — home proxy unreachable" do
    before do
      allow(control).to receive(:info)
      allow(TeslaCommand).to receive(:broadcast)
      # Critical: do NOT post to Slack on proxy-unreachable.
      allow(control).to receive(:err)
    end

    TeslaControl::PROXY_UNREACHABLE_ERRORS.each do |klass|
      it "returns false + logs info (not err) when #{klass} is raised" do
        called = 0
        result = control.send(:wakeup_retry) {
          called += 1
          raise klass, "boom"
        }
        expect(result).to be(false)
        expect(called).to eq(1)
        expect(control).not_to have_received(:err)
        expect(control).to have_received(:info).with(/Home proxy unreachable/, /#{klass.name}/)
      end
    end
  end
end
