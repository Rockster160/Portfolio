class BackfillChoreHouseholds < ActiveRecord::Migration[7.1]
  # Strategy:
  #   1. Each connected component of the chore_shares graph becomes one
  #      household; lowest user_id wins ownership.
  #   2. Chore-owning users outside any component get a solo household.
  #   3. All members get role=manager (owner included).
  #   4. chore_household_id stamped on chores, streak bonuses, and users.
  #   5. Multi-user households rewrite chore.sort_order from the owner's
  #      chore_user_orders; chores missing from that table fall to the
  #      end by id. Solo households keep their existing sort_order.
  def up
    execute("SET LOCAL synchronous_commit = off") # safe — single migration tx

    closures = build_closures
    creator_user_ids = ActiveRecord::Base.connection.select_values(
      "SELECT DISTINCT created_by_user_id FROM chores",
    ).map(&:to_i)
    solo_user_ids = creator_user_ids - closures.flatten

    closures.each { |user_ids| build_household(user_ids) }
    solo_user_ids.each { |uid| build_household([uid]) }
  end

  def down
    execute("UPDATE users SET chore_household_id = NULL")
    execute("UPDATE chores SET chore_household_id = NULL")
    execute("UPDATE chore_streak_bonuses SET chore_household_id = NULL")
    execute("DELETE FROM chore_household_memberships")
    execute("DELETE FROM chore_households")
  end

  private

  def build_closures
    edges = ActiveRecord::Base.connection.select_rows(
      "SELECT user_id, shared_with_user_id FROM chore_shares",
    ).map { |a, b| [a.to_i, b.to_i] }

    adj = Hash.new { |h, k| h[k] = Set.new }
    edges.each { |a, b| adj[a] << b; adj[b] << a }

    seen = Set.new
    components = []
    adj.each_key do |start|
      next if seen.include?(start)

      component = Set.new
      frontier = [start]
      until frontier.empty?
        node = frontier.shift
        next unless seen.add?(node)

        component << node
        adj[node].each { |n| frontier << n unless seen.include?(n) }
      end
      components << component.to_a.sort
    end
    components
  end

  def build_household(user_ids)
    owner_id = user_ids.min
    owner_username = ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(["SELECT username FROM users WHERE id = ?", owner_id]),
    )
    name = user_ids.size == 1 ? "#{owner_username || "User #{owner_id}"}'s Household" : "Household"
    now = Time.current.utc.iso8601

    household_id = ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array([
        "INSERT INTO chore_households (owner_user_id, name, created_at, updated_at) " \
        "VALUES (?, ?, ?, ?) RETURNING id",
        owner_id, name, now, now,
      ]),
    )

    user_ids.each do |uid|
      ActiveRecord::Base.connection.execute(
        ActiveRecord::Base.sanitize_sql_array([
          "INSERT INTO chore_household_memberships " \
          "(chore_household_id, user_id, role, created_at, updated_at) " \
          "VALUES (?, ?, ?, ?, ?)",
          household_id, uid, 1, now, now, # role=1 → :manager
        ]),
      )
    end

    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql_array([
        "UPDATE chores SET chore_household_id = ? WHERE created_by_user_id IN (?)",
        household_id, user_ids,
      ]),
    )

    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql_array([
        "UPDATE chore_streak_bonuses SET chore_household_id = ? WHERE user_id IN (?)",
        household_id, user_ids,
      ]),
    )

    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql_array([
        "UPDATE users SET chore_household_id = ? WHERE id IN (?)",
        household_id, user_ids,
      ]),
    )

    rewrite_sort_order(household_id, owner_id) if user_ids.size > 1
  end

  def rewrite_sort_order(household_id, owner_id)
    rows = ActiveRecord::Base.connection.select_rows(
      ActiveRecord::Base.sanitize_sql_array([
        "SELECT c.id, cuo.sort_order FROM chores c " \
        "LEFT JOIN chore_user_orders cuo " \
        "  ON cuo.chore_id = c.id AND cuo.user_id = ? " \
        "WHERE c.chore_household_id = ? " \
        "ORDER BY cuo.sort_order ASC NULLS LAST, c.id ASC",
        owner_id, household_id,
      ]),
    )

    rows.each_with_index do |(chore_id, _), idx|
      ActiveRecord::Base.connection.execute(
        ActiveRecord::Base.sanitize_sql_array([
          "UPDATE chores SET sort_order = ? WHERE id = ?",
          idx, chore_id.to_i,
        ]),
      )
    end
  end
end
