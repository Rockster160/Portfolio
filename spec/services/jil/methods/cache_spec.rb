RSpec.describe "Jil Cache Operations" do
  include ActiveJob::TestHelper

  let(:user) { User.me }
  let(:execute) { Jil::Executor.call(user, code, {}) }
  let(:ctx) { execute.ctx }

  describe "set_cache and get_cache" do
    let(:code) {
      <<~'JIL'
        a1 = Global.set_cache("test_ns", "mykey", "hello")::Any
        a2 = Global.get_cache("test_ns", "mykey")::String
      JIL
    }

    after { user.caches.find_by(key: "test_ns")&.destroy }

    it "stores and retrieves a value" do
      expect(ctx[:error]).to be_blank
      expect(ctx.dig(:vars, :a2, :value)).to eq("hello")
    end
  end

  describe "del_cache removes a subkey" do
    let(:code) {
      <<~'JIL'
        a1 = Global.set_cache("test_ns", "foo", "bar")::Any
        a2 = Global.set_cache("test_ns", "other", "keep")::Any
        a3 = Global.del_cache("test_ns", "foo")::Boolean
        a4 = Global.get_cache("test_ns", "foo")::Any
        a5 = Global.get_cache("test_ns", "other")::String
      JIL
    }

    after { user.caches.find_by(key: "test_ns")&.destroy }

    it "deletes the specified subkey and leaves others" do
      expect(ctx[:error]).to be_blank
      expect(ctx.dig(:vars, :a4, :value)).to be_nil
      expect(ctx.dig(:vars, :a5, :value)).to eq("keep")
    end
  end

  describe "del_cache after set_cache in the same execution" do
    let(:code) {
      <<~'JIL'
        test_data = Hash.new({
          a1 = Keyval.new("name", "Slime")::Keyval
          a2 = Keyval.new("est", 1440)::Keyval
        })::Hash
        a3 = Global.set_cache("test_ns", "current", test_data)::Any
        a4 = Global.get_cache("test_ns", "current")::Hash
        a5 = Global.del_cache("test_ns", "current")::Boolean
        a6 = Global.get_cache("test_ns", "current")::Any
      JIL
    }

    after { user.caches.find_by(key: "test_ns")&.destroy }

    it "deletes the key that was just set" do
      expect(ctx[:error]).to be_blank
      # Verify it was set
      expect(ctx.dig(:vars, :a4, :value)).to be_present
      # Verify it was deleted
      expect(ctx.dig(:vars, :a6, :value)).to be_nil
    end
  end

  describe "del_cache with no subkey destroys entire cache record" do
    let(:code) {
      <<~'JIL'
        a1 = Global.set_cache("test_del_all", "foo", "bar")::Any
        a2 = Global.del_cache("test_del_all", "")::Boolean
        a3 = Global.get_cache("test_del_all", "foo")::Any
      JIL
    }

    after { user.caches.find_by(key: "test_del_all")&.destroy }

    it "destroys the entire cache namespace" do
      expect(ctx[:error]).to be_blank
      expect(ctx.dig(:vars, :a3, :value)).to be_nil
    end
  end
end
