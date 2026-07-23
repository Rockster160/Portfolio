require "rails_helper"

RSpec.describe ApplicationCable::Connection do
  let(:user) { FactoryBot.create(:user) }
  let(:session_key) { Rails.application.config.session_options[:key] }

  def build_conn(signed: {}, encrypted: {}, headers: {})
    conn = ApplicationCable::Connection.allocate

    cookie_jar = Class.new do
      def initialize(signed_h, encrypted_h)
        @signed = signed_h.with_indifferent_access
        @encrypted = encrypted_h.with_indifferent_access
      end
      def signed = @signed
      def encrypted = @encrypted
      def permanent = @signed
    end.new(signed, encrypted)

    conn.define_singleton_method(:cookies) { cookie_jar }
    conn.define_singleton_method(:request) { OpenStruct.new(headers: headers, parameters: {}) }
    conn
  end

  it "connects via the signed current_user_id cookie" do
    conn = build_conn(signed: { current_user_id: user.id })

    expect(conn.send(:find_verified_user)).to eq(user)
  end

  it "falls back to the domain-scoped session cookie when the signed cookie is missing" do
    conn = build_conn(encrypted: { session_key => { "current_user_id" => user.id } })

    expect(conn.send(:find_verified_user)).to eq(user)
  end

  it "rejects when no auth source is present" do
    conn = build_conn
    expect(conn).to receive(:reject_unauthorized_connection)

    conn.send(:find_verified_user)
  end
end
