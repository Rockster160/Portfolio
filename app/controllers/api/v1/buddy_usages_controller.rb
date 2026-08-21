class Api::V1::BuddyUsagesController < Api::V1::BaseController
  skip_before_action :verify_authenticity_token

  # Spend recorded away from production, handed over by `bx rails buddy:usage_sync`.
  #
  # Deduped on `origin_uid` rather than trusted to arrive once: a batch that
  # times out after the insert looks identical from the other end to one that
  # never landed, so the spool re-sends the whole file and this decides what is
  # new. `created_at` comes from the payload — the money was spent when it was
  # spent, and stamping it now would pile a month of evals onto today.
  MAX_BATCH = 500

  PERMITTED = %i[
    origin_uid
    env
    kind
    model
    input_tokens
    cached_input_tokens
    output_tokens
    reasoning_tokens
    cost_micros
    username
    recorded_at
  ].freeze

  def create
    rows = Array(params[:usages]).map { |row| row.permit(PERMITTED).to_h.symbolize_keys }
    if rows.length > MAX_BATCH
      return render_json(error: "Too many usages in one batch", status: :unprocessable_entity)
    end

    counts = { received: rows.length, created: 0, duplicate: 0, skipped: 0 }
    rows.each { |row| counts[record(row)] += 1 }

    render_json(counts)
  end

  private

  def record(row)
    return :skipped unless recordable?(row)
    return :duplicate if BuddyUsage.exists?(origin_uid: row[:origin_uid])

    BuddyUsage.create!(
      user:                user_for(row),
      origin_uid:          row[:origin_uid],
      env:                 row[:env],
      kind:                row[:kind],
      model:               row[:model],
      input_tokens:        row[:input_tokens].to_i,
      cached_input_tokens: row[:cached_input_tokens].to_i,
      output_tokens:       row[:output_tokens].to_i,
      reasoning_tokens:    row[:reasoning_tokens].to_i,
      cost_micros:         row[:cost_micros].to_i,
      created_at:          recorded_at(row),
    )
    :created
  rescue ActiveRecord::RecordNotUnique
    :duplicate
  end

  # An env or kind this build has never heard of is a newer laptop talking to an
  # older server, and a timestamp that won't parse is a row whose spend has no
  # day to sit on. Both are counted as skipped rather than filed under the
  # nearest name that fits: the sync says so out loud, the spool archive still
  # has the line, and nothing lands claiming to be something it isn't.
  def recordable?(row)
    row[:origin_uid].present? &&
      row[:model].present? &&
      BuddyUsage.envs.key?(row[:env].to_s) &&
      BuddyUsage.kinds.key?(row[:kind].to_s) &&
      recorded_at(row).present?
  end

  def recorded_at(row)
    Time.zone.parse(row[:recorded_at].to_s)
  rescue ArgumentError
    nil
  end

  # A row names the person it was spent by, but only the account that can see
  # everyone's spend is allowed to file it against someone else.
  def user_for(row)
    named = row[:username].present? && User.find_by(username: row[:username])
    return named if named && (named.id == current_user.id || current_user.me?)

    current_user
  end
end
