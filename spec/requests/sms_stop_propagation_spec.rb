require "rails_helper"

RSpec.describe IndexController, type: :controller do
  describe "POST #talk — :sms trigger stop_propagation" do
    let!(:user) { create(:user, phone: "5550009999") }

    let(:sms_params) {
      { "From" => "+15550009999", "To" => "+15555550001", "Body" => "chore washed dishes" }
    }

    before do
      allow(::Jarvis).to receive(:command).and_return([nil, nil])
      allow(::Jarvis).to receive(:say)
    end

    # rspec-mocks' verify_partial_doubles trips on Ruby 3 kwargs separation
    # when stubbing Jil.trigger directly — patch the underlying executor.
    def stub_trigger(returning:)
      allow(::Jil::Executor).to receive(:trigger) { |_u, _scope, _data, **_kw| returning }
    end

    it "skips Jarvis.command when an :sms task calls stop_propagation" do
      stopped_task = instance_double(Task, stop_propagation?: true)
      stub_trigger(returning: [stopped_task])

      post :talk, params: sms_params

      expect(response).to have_http_status(:ok)
      expect(::Jarvis).not_to have_received(:command)
    end

    it "still calls Jarvis.command when no :sms task stops propagation, or none match" do
      [[instance_double(Task, stop_propagation?: false)], []].each do |tasks|
        stub_trigger(returning: tasks)

        post :talk, params: sms_params

        expect(response).to have_http_status(:ok)
      end
      expect(::Jarvis).to have_received(:command).with(user, "chore washed dishes").twice
    end
  end
end
