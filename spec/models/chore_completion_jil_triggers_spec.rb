RSpec.describe ChoreCompletion, "Jil lifecycle triggers" do
  let(:user) { User.me }
  let!(:chore) { Chore.create!(name: "Wordle", created_by_user_id: user.id, reward_pebbles: 5) }

  let(:fired) { [] }

  before {
    allow(::Jil).to receive(:trigger) { |target, scope, payload, **|
      fired << [target, scope, payload.execution_attrs]
    }
  }

  it "fires :completed on create with jil_attrs payload" do
    chore.chore_completions.create!(
      user: user, completed_at: Time.current, day_key: ChoreDay.current(user),
    )

    _target, scope, attrs = fired.first
    expect(scope).to eq(:chore_completion)
    expect(attrs[:action]).to eq(:completed)
    expect(attrs[:chore_name]).to eq("Wordle")
    expect(attrs[:completed_by_user_id]).to eq(user.id)
    expect(attrs[:completed_by_username]).to eq(user.username)
  end

  it "fires ONLY :completed on create (no :edited double-fire from after_update_commit)" do
    chore.chore_completions.create!(
      user: user, completed_at: Time.current, day_key: ChoreDay.current(user),
    )

    actions = fired.map { |_target, _scope, attrs| attrs[:action] }
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
    _target, scope, attrs = fired.first
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

    _target, scope, attrs = fired.first
    expect(scope).to eq(:chore_completion)
    expect(attrs[:action]).to eq(:uncompleted)
  end

  describe "household fan-out" do
    let(:other) { create(:user) }
    let!(:household) { share_chore_household!(user, other) }
    let!(:shared_chore) {
      Chore.create!(
        name: "Take trash cans out", created_by_user_id: user.id,
        chore_household: household, sharing_mode: :household, reward_pebbles: 5,
      )
    }

    let(:completion_targets) {
      fired.select { |_target, scope, _attrs| scope == :chore_completion }.map { |target, _s, _a| target.id }
    }
    let(:completion_attrs) {
      _target, _scope, attrs = fired.find { |_target, scope, _attrs| scope == :chore_completion }
      attrs
    }

    it "fires the :completed trigger for every household member when a member completes a household chore" do
      shared_chore.chore_completions.create!(
        user: other, completed_at: Time.current, day_key: ChoreDay.current(other),
      )

      expect(completion_targets).to match_array(household.members.pluck(:id))
      expect(completion_attrs[:completed_by_user_id]).to eq(other.id)
      expect(completion_attrs[:completed_by_username]).to eq(other.username)
    end

    it "still fires only for the completing user on a personal chore" do
      personal = Chore.create!(
        name: "Wordle Solo", created_by_user_id: other.id,
        chore_household: household, sharing_mode: :personal, reward_pebbles: 5,
      )
      personal.chore_completions.create!(
        user: other, completed_at: Time.current, day_key: ChoreDay.current(other),
      )

      expect(completion_targets).to eq([other.id])
    end
  end
end
