# The order the Feature Builder's PRs are merged in. Every build with an open
# PR has a place in it; the owner approves (here or with a GitHub review),
# reorders, and holds. The first approved build that isn't held is handed the
# merge (`land` on the Mini): its own session catches up with master, makes
# its changes fit what master is now, and then merges, closes itself, or asks
# for another review. A merge holds the line until production is running it
# and answering, so each deploy ships and is checked before the next merge.
#
# Nothing polls. The line moves whenever something that could free it
# happens: an approval, a reorder, a build finishing or asking again, a deploy
# booting, and any report from the Mini, which also retries a hand-off the
# Mini missed.
module MergeQueue
  module_function

  # A session that merges past this without a word stops holding the line.
  LANDING_TIMEOUT = 2.hours
  MOVES = %i[top up down bottom].freeze

  # Every build with an open PR, in the order they merge.
  def builds(user)
    scope = FeatureBuild.where(user: user).unfinished.where.not(pr_url: nil)
    scope.order(Arel.sql("queue_position ASC NULLS LAST"), :id)
  end

  # landing   merging now
  # held      set aside; passed over until it's released
  # approved  next in line, in order
  # answer    its session stopped on something it said to the owner
  # review    the PR waits on the owner's review
  def state(build)
    return :landing if landing?(build)
    return :held if build.held?
    return :approved if build.approved_at
    return :answer if build.question.present?

    :review
  end

  def landing?(build)
    build.landing_at.present? && build.landing_at > LANDING_TIMEOUT.ago
  end

  # A PR just opened goes to the back of the line.
  def enqueue!(build)
    return if build.queue_position

    last = FeatureBuild.where(user: build.user).maximum(:queue_position).to_i
    build.update!(queue_position: last + 1)
  end

  def approve!(build)
    build.update!(approved_at: Time.current)
    advance!(build.user)
  end

  def unapprove!(build)
    build.update!(approved_at: nil)
  end

  def hold!(build, held)
    build.update!(held: held)
    advance!(build.user)
  end

  def move!(build, direction)
    queue = builds(build.user).to_a
    index = queue.index(build)
    return if index.nil?

    queue.delete_at(index)
    target = (
      case direction.to_sym
      when :top    then 0
      when :up     then [index - 1, 0].max
      when :down   then [index + 1, queue.length].min
      when :bottom then queue.length
      else index
      end
    )
    queue.insert(target, build)
    queue.each_with_index { |queued, position|
      queued.update!(queue_position: position + 1) unless queued.queue_position == position + 1
    }
    advance!(build.user)
  end

  # Merged builds whose deploy hasn't been seen live yet. A deploy that fails
  # never boots, so the line stays held until someone looks.
  def deploying(user)
    FeatureBuild.where(user: user).where.not(merge_sha: nil).where(deployed_at: nil)
  end

  # Called after each deploy boots, from the new code: anything it brought in
  # is live once the site answers, and the line moves on. Returns whether
  # anything was left waiting.
  def deployed!
    waiting = FeatureBuild.where.not(merge_sha: nil).where(deployed_at: nil).to_a
    live = waiting.select { |build| ProductionScripts.deployed?(build.merge_sha) }
    return waiting.any? if live.empty? || !site_up?

    live.each { |build| build.update!(deployed_at: Time.current) }
    live.map(&:user).uniq.each { |user| advance!(user) }
    waiting.length > live.length
  end

  def site_up?
    url = Rails.application.routes.url_helpers.root_url
    Net::HTTP.get_response(URI(url)).code.to_i < 500
  rescue StandardError
    false
  end

  # The build is out of the line: merged, closed, or back to the owner.
  def released!(build, approved: false)
    build.reload
    build.update!(landing_at: nil, approved_at: (build.approved_at if approved))
    advance!(build.user)
  end

  # Hands the merge to the first approved build that isn't held, unless one
  # has it already. One that sat on it past LANDING_TIMEOUT gives it up, and
  # its approval with it, so it isn't handed the same thing again at once.
  def advance!(user)
    ActiveRecord::Base.transaction {
      User.lock.find(user.id)
      queue = builds(user).to_a
      next if queue.any? { |build| landing?(build) }
      next if deploying(user).exists?

      queue.select(&:landing_at).each { |stale| stale.update!(landing_at: nil, approved_at: nil) }
      nxt = queue.find { |build| build.approved_at && !build.held? }
      next if nxt.nil?

      nxt.update!(landing_at: Time.current) if ByteLocal.builder(:land, build_id: nxt.id)
    }
  end
end
