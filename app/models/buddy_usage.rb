# == Schema Information
#
# Table name: buddy_usages
#
#  id                   :bigint           not null, primary key
#  cached_input_tokens  :integer          default(0), not null
#  cost_micros          :bigint           default(0), not null
#  input_tokens         :integer          default(0), not null
#  kind                 :integer          default("turn"), not null
#  model                :string           not null
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
  # `eval` is the buddy:eval rake harness. It bills exactly like a turn, so it
  # has to be recorded, but it must stay separable: a few eval runs can dwarf a
  # day of real use, and folding them into the same total would make the
  # projected bill meaningless.
  enum :kind, { turn: 0, compaction: 1, eval: 2 }

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
    )
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
