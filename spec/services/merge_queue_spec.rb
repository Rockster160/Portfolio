require "rails_helper"

RSpec.describe MergeQueue do
  let(:user) { User.me }
  let!(:first)  { build_with_pr("First", 1) }
  let!(:second) { build_with_pr("Second", 2) }
  let!(:third)  { build_with_pr("Third", 3) }
  let(:handed) { [] }

  def build_with_pr(title, number)
    FeatureBuild.create!(
      user:      user,
      title:     title,
      request:   title,
      status:    :running,
      pr_number: number,
      pr_url:    "https://github.com/Rockster160/Portfolio/pull/#{number}",
    ).tap { |build| described_class.enqueue!(build) }
  end

  before {
    allow(ByteLocal).to receive(:builder) { |action, build_id:, **|
      handed << build_id if action == :land
      true
    }
  }

  it "lines PRs up in the order they opened, and reorders them" do
    expect(described_class.builds(user)).to eq([first, second, third])

    described_class.move!(third, :top)
    described_class.move!(first, :down)

    expect(described_class.builds(user)).to eq([third, second, first])
  end

  it "hands the merge to the first approved build that isn't held, one at a time" do
    described_class.hold!(first, true)
    described_class.approve!(first)
    described_class.approve!(third)
    described_class.approve!(second)

    expect(handed).to eq([third.id])
    expect(described_class.state(third.reload)).to eq(:landing)
    expect(described_class.state(second.reload)).to eq(:approved)
    expect(described_class.state(first.reload)).to eq(:held)
  end

  it "moves on once the one merging is out of the line, and leaves the rest waiting on review" do
    described_class.approve!(second)
    described_class.approve!(third)

    second.update!(status: :finished)
    described_class.released!(second)

    expect(handed).to eq([second.id, third.id])
    expect(described_class.state(first.reload)).to eq(:review)
  end

  it "takes the turn and the approval from one that sat on it too long" do
    first.update!(approved_at: 3.hours.ago, landing_at: 3.hours.ago)
    described_class.approve!(second)

    expect(handed).to eq([second.id])
    expect(first.reload.approved_at).to be_nil
  end

  it "doesn't count a hand-off the Mini never took" do
    allow(ByteLocal).to receive(:builder).and_return(false)

    described_class.approve!(first)

    expect(first.reload.landing_at).to be_nil
    expect(described_class.state(first)).to eq(:approved)
  end

  it "says when a build is waiting on an answer rather than a review" do
    first.update!(question: "Dark by default?")

    expect(described_class.state(first)).to eq(:answer)
  end
end
