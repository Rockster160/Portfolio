require "rails_helper"

# A closed list of real URLs, for the same reason `call_jil_function` refuses
# to invent a function name: a guessed URL fails silently. A link to a path
# that isn't routed looks exactly like a working one until it's tapped.
RSpec.describe Buddy::AppPages do
  let(:owner) { User.me }
  let(:other) { create(:user) }

  describe "what everyone gets" do
    it "hands over the links page, since that's the one with no other way in" do
      page = described_class.for_user(other).find { |p| p[:name] == :links }

      expect(page[:url]).to end_with("/chores/links")
      expect(page[:about]).to match(/record links/i)
    end

    it "gives absolute urls, because a relative one would resolve against the Byte subdomain" do
      described_class.for_user(other).each { |page|
        expect(page[:url]).to start_with("http")
      }
    end

    # The whole reason this is a closed list. Compared against the route set
    # rather than `recognize_path`, which can't evaluate a constraint without a
    # real request and so reports /system as unroutable.
    it "points every url at a path the app actually routes" do
      routed = Rails.application.routes.routes.to_set { |r|
        r.path.spec.to_s.sub(/\(\.:format\)\z/, "")
      }

      described_class.for_user(owner).each { |page|
        path = URI.parse(page[:url]).path
        expect(routed).to include(path), "#{page[:name]} points at #{path}, which isn't routed"
      }
    end
  end

  # /system is behind MeConstraint. Offering it to someone who'd be bounced is
  # worse than not mentioning it, because they can see it and can't use it.
  describe "owner-only pages" do
    it "offers system dashboards to the owner" do
      expect(described_class.for_user(owner).pluck(:name)).to include(:system)
    end

    it "hides them from everyone else" do
      expect(described_class.for_user(other).pluck(:name)).not_to include(:system)
    end

    it "hides them from nobody at all" do
      expect(described_class.for_user(nil)).to eq([])
    end
  end

  describe "as a context section" do
    it "is fetchable rather than sitting in the prompt on every turn" do
      expect(Buddy::GPT::ContextTool::SECTIONS).to include(:app_pages)
    end

    it "rides in the full context for the user it was built for" do
      convo = other.byte_conversations.create!(mode: :buddy, last_message_at: Time.current)

      names = Buddy::Context.full(other, convo)[:app_pages].pluck(:name)

      expect(names).to include(:links, :chores)
      expect(names).not_to include(:system)
    end
  end
end
