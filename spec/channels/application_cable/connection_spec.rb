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

  it "connects via a bearer API key" do
    key = user.api_keys.create!(name: "Dashboard")
    conn = build_conn(headers: { "HTTP_AUTHORIZATION" => "Bearer #{key.key}" })

    expect(conn.send(:find_verified_user)).to eq(user)
  end

  # An API key is hex, and `user_from_headers` base64-decodes it; a decoded key
  # can contain a colon without being basic auth. This key is pinned because it
  # decodes to one.
  it "connects with a key whose bytes happen to contain a colon" do
    key = user.api_keys.create!(name: "Unlucky", key: "07431DF91B793A558680A6FA9A8AB5A6")
    expect(Base64.decode64(key.key)).to include(":")
    conn = build_conn(headers: { "HTTP_AUTHORIZATION" => "Bearer #{key.key}" })

    expect(conn.send(:find_verified_user)).to eq(user)
  end

  it "still accepts genuine basic auth" do
    user.update!(password: "correct-horse", password_confirmation: "correct-horse")
    token = Base64.encode64("#{user.username}:correct-horse")
    conn = build_conn(headers: { "HTTP_AUTHORIZATION" => "Basic #{token}" })

    expect(conn.send(:find_verified_user)).to eq(user)
  end

  # A socket outlives the request that opened it, so a key that's been turned
  # off getting one is a key that keeps listening for as long as it stays open.
  it "rejects a bearer API key that's been disabled" do
    key = user.api_keys.create!(name: "Old laptop")
    key.update!(enabled: false)
    conn = build_conn(headers: { "HTTP_AUTHORIZATION" => "Bearer #{key.key}" })
    expect(conn).to receive(:reject_unauthorized_connection)

    conn.send(:find_verified_user)
  end
end
