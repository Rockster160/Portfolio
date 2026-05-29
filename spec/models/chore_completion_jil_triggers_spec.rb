RSpec.describe ChoreCompletion, "Jil lifecycle triggers" do
  let(:user) { User.me }
  let!(:chore) { Chore.create!(name: "Wordle", created_by_user_id: user.id, reward_pebbles: 5) }

  let(:fired) { [] }

  before {
    allow(::Jil).to receive(:trigger) { |_user, scope, payload, **|
      fired << [scope, payload.execution_attrs]
    }
  }

  it "fires :completed on create with jil_attrs payload" do
    chore.chore_completions.create!(
      user: user, completed_at: Time.current, day_key: ChoreDay.current(user),
    )

    scope, attrs = fired.first
    expect(scope).to eq(:chore_completion)
    expect(attrs[:action]).to eq(:completed)
    expect(attrs[:chore_name]).to eq("Wordle")
  end

  it "fires ONLY :completed on create (no :edited double-fire from after_update_commit)" do
    chore.chore_completions.create!(
      user: user, completed_at: Time.current, day_key: ChoreDay.current(user),
    )

    actions = fired.map { |_scope, attrs| attrs[:action] }
    expect(actions).to eq([:completed])
  end

  it "fires :edited on update with saved_changes included" do
    completion = chore.chore_completions.create!(
      user: user, completed_at: Time.current, day_key: ChoreDay.current(user),
    )
    fired.clear

    new_at = 1.hour.ago
    completion.update!(completed_at: new_at)

    expect(fired.length).to eq(1)
    scope, attrs = fired.first
    expect(scope).to eq(:chore_completion)
    expect(attrs[:action]).to eq(:edited)
    expect(attrs[:changes]).to be_a(Hash)
    expect(attrs[:changes]["completed_at"]).to be_an(Array)
    expect(attrs[:changes]["completed_at"].last).to be_within(1.second).of(new_at)
  end

  it "does NOT fire :edited when nothing changed (touch-only save short-circuit)" do
    completion = chore.chore_completions.create!(
      user: user, completed_at: Time.current, day_key: ChoreDay.current(user),
    )
    fired.clear

    completion.save! # no attribute changes

    expect(fired).to be_empty
  end

  it "fires :uncompleted on destroy" do
    completion = chore.chore_completions.create!(
      user: user, completed_at: Time.current, day_key: ChoreDay.current(user),
    )
    fired.clear

    completion.destroy!

    scope, attrs = fired.first
    expect(scope).to eq(:chore_completion)
    expect(attrs[:action]).to eq(:uncompleted)
  end
end
