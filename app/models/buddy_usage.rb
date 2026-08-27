# == Schema Information
#
# Table name: buddy_usages
#
#  id                   :bigint           not null, primary key
#  cached_input_tokens  :integer          default(0), not null
#  cost_micros          :bigint           default(0), not null
#  env                  :integer          default("production"), not null
#  input_tokens         :integer          default(0), not null
#  kind                 :integer          default("turn"), not null
#  model                :string           not null
#  origin_uid           :string
#  output_tokens        :integer          default(0), not null
#  reasoning_tokens     :integer          default(0), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  byte_conversation_id :bigint
#  byte_message_id      :bigint
#  user_id              :bigint           not null
#
class BuddyUsage < ApplicationRecord
  # One model API call: what it consumed and what it cost.
  #
  # A single Buddy turn writes several of these when it round-trips through
  # get_context, so per-message cost is a SUM over byte_message_id rather than a
  # single row. Compaction writes a row with no message attached.
  belongs_to :user
  belongs_to :byte_conversation, optional: true
  belongs_to :byte_message, optional: true

  # NOTE: never reassign existing integers — enum order is persisted.
  #
  # `eval` is the buddy:eval harness. It bills exactly like a turn, so it
  # has to be recorded, but it must stay separable: a few eval runs can dwarf a
  # day of real use, and folding them into the same total would make the
  # projected bill meaningless.
  # `idea_note` is Buddy::IdeaDwell settling a stretch of conversation onto the
  # idea it was about. It bills like a compaction and is just as invisible, but
  # it's the one kind nobody asked for per-turn, so it stays separable.
  # `compile` is Buddy::Compile — the background pass that reads a finished
  # stretch and writes memories and follow-ups off it. Its own kind rather than
  # folded into `idea_note`, so the first time either number looks wrong it's
  # possible to tell which one moved.
  # `image_describe` is Buddy::ImageDescriber writing what a picture is of, once,
  # when it arrives. Separable because it is the only one that scales with
  # PHOTOS rather than with turns: a day of sending twenty pictures and barely
  # talking looks nothing like a day of talking, and folded in it would read as
  # a conversation that cost a fortune.
  enum :kind, { turn: 0, compaction: 1, eval: 2, idea_note: 3, compile: 4, image_describe: 5 }

  # Where the call was made. Prod only ever saw its own rows until local spend
  # started syncing in, and without this the bill reads as if the laptop were
  # free. Crossed with `kind` it says which of the three local things it was:
  # an eval sweep (development + eval), poking Byte on localhost (development +
  # anything else), or the spec suite (test).
  #
  # `test` rows are fabricated — the fake client invents its token counts — so
  # they are recorded for completeness and excluded from spend.
  enum :env, { production: 0, development: 1, test: 2 }, prefix: :from

  # `origin_uid` is set only on rows that arrived from somewhere else. It names
  # the machine and the row that spent the money, and it is what the prod copy
  # dedupes on, so re-sending a spool file is harmless.
  scope :billed,   -> { where.not(env: :test) }
  scope :synced,   -> { where.not(origin_uid: nil) }
  scope :unsynced, -> { where(origin_uid: nil) }

  scope :chronological, -> { order(created_at: :asc) }
  scope :since,         ->(time) { where(created_at: time...) }
  scope :between,       ->(from, to) { where(created_at: from...to) }

  # Record one call. Takes the client's result hash directly so callers don't
  # have to know the usage field names or the cost math.
  #
  # Returns nil when the call reported no usage (a rejected request bills
  # nothing, so there is nothing to record).
  def self.record!(result, user:, kind: :turn, conversation: nil, message: nil)
    usage = result[:usage]
    return nil if usage.blank?

    model = result[:model].to_s
    create!(
      user:                user,
      byte_conversation:   conversation,
      byte_message:        message,
      kind:                kind,
      model:               model,
      input_tokens:        usage[:input_tokens].to_i,
      cached_input_tokens: usage[:cached_input_tokens].to_i,
      output_tokens:       usage[:output_tokens].to_i,
      reasoning_tokens:    usage[:reasoning_tokens].to_i,
      cost_micros:         Buddy::GPT::Pricing.cost_micros(usage, model: model),
      env:                 Rails.env,
    ).tap { |row| Buddy::UsageSpool.append!(row) }
  end

  # Total spend for a scope, in micro-dollars.
  def self.spend_micros
    sum(:cost_micros)
  end

  # Per-message rollup, the shape mirrored onto ByteMessage#metadata["usage"] so
  # the client can render a cost without joining.
  def self.rollup_for_message(message)
    rows = where(byte_message_id: message.id)
    return nil if rows.empty?

    {
      "calls"               => rows.count,
      "model"               => rows.first.model,
      "input_tokens"        => rows.sum(:input_tokens),
      "cached_input_tokens" => rows.sum(:cached_input_tokens),
      "output_tokens"       => rows.sum(:output_tokens),
      "cost_micros"         => rows.sum(:cost_micros),
    }
  end

  # The portion of input that hit the prompt cache. Buddy's system prompt and
  # tool schemas are a stable ~23k-token prefix, so a healthy number here is
  # high — a persistently low one means the prefix is being invalidated and the
  # turn is costing ~10x more input than it needs to.
  def cache_hit_rate
    return 0.0 if input_tokens.zero?

    cached_input_tokens / input_tokens.to_f
  end

  def cost_usd
    cost_micros / Buddy::GPT::Pricing::MICROS_PER_DOLLAR.to_f
  end

  def to_s
    "#{kind} #{model} in=#{input_tokens}(#{cached_input_tokens} cached) " \
      "out=#{output_tokens} #{Buddy::GPT::Pricing.format_micros(cost_micros)}"
  end
end
