# Small helper for specs that just need two (or more) users sharing a
# chore household — the most common chore test fixture. Mirrors the
# old `create(:chore_share, user: A, shared_with_user: B)` ergonomics.
module ChoreHouseholdHelpers
  # share_chore_household!(alice, bob)              → both in alice's household
  # share_chore_household!(alice, bob, role: :member)
  def share_chore_household!(owner, *others, role: :manager)
    existing = ChoreHouseholdMembership.where(user_id: owner.id).first
    household = existing&.chore_household || create(:chore_household, owner_user: owner)
    others.each do |other|
      ChoreHouseholdMembership.find_or_create_by!(chore_household: household, user: other) { |m| m.role = role }
      other.reload
    end
    owner.reload
    household
  end
end

RSpec.configure do |c|
  c.include ChoreHouseholdHelpers
end
