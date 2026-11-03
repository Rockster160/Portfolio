require "rails_helper"

RSpec.describe PlaygroundProject do
  let(:guest) { User.create!(role: :guest) }
  let(:member) { FactoryBot.create(:user) }
  let(:admin) { FactoryBot.create(:user, role: :admin) }

  def request_for(path, subdomain: "")
    instance_double(ActionDispatch::Request, path: path, subdomain: subdomain)
  end

  it "resolves every listed project's page from its route helper" do
    described_class.listed.select(&:openable?).each do |project|
      next if project.subdomain.present?

      expect(project.entry_path).to start_with("/"), "#{project.slug} has no path"
    end
  end

  # The copy is drafted by GPT, which has handed back objects where strings
  # belong; the page would print those as raw hashes.
  it "has About copy in the shape the page renders" do
    described_class.listed.each do |project|
      about = project.about
      expect(about[:tagline]).to be_a(String).or(be_nil), "#{project.slug} has a malformed tagline"
      expect(about[:body]).to be_a(String).or(be_nil), "#{project.slug} has a malformed body"
      project.screenshots.each do |shot|
        expect(Rails.public_path.join("playground", project.slug, shot[:file])).to exist
      end
    end
  end

  it "has unique slugs" do
    slugs = described_class.all.map(&:slug)
    expect(slugs).to eq(slugs.uniq)
  end

  it "only finds listed projects" do
    expect(described_class.find(:timers)&.title).to eq("Timers")
    expect(described_class.find(:emails)).to be_nil
  end

  describe ".for_request" do
    # The longest matching path wins, a shared prefix is not a match, and an
    # unlisted project is never found.
    it "maps a request to the listed project it belongs to", :aggregate_failures do
      [
        ["/chores/links", "", "chores"],
        ["/jil/tasks/1", "", "jil"],
        ["/", "byte", "byte"],
        ["/timersfoo", "", nil],
        ["/emails", "", nil],
      ].each do |path, subdomain, slug|
        expect(described_class.for_request(request_for(path, subdomain: subdomain))&.slug).to eq(slug), path
      end
    end
  end

  describe "#open_to?" do
    it "opens a guest-level project to everyone" do
      chores = described_class.find(:chores)
      expect([nil, guest, member].map { |user| chores.open_to?(user) }).to all(be(true))
    end

    it "needs a registered account for an account-level project" do
      timers = described_class.find(:timers)
      expect([nil, guest, member].map { |user| timers.open_to?(user) }).to eq([false, false, true])
    end

    it "keeps an owner-level project to the owner" do
      system = described_class.find(:system)
      owner = FactoryBot.create(:user, role: :admin)
      allow(owner).to receive(:me?).and_return(true)
      expect([nil, member, admin, owner].map { |user| system.open_to?(user) }).to eq([false, false, false, true])
    end

    it "never opens a project with no page" do
      jarvis = described_class.find(:jarvis)
      owner = member
      allow(owner).to receive(:me?).and_return(true)
      expect(jarvis.open_to?(owner)).to be(false)
    end
  end
end
