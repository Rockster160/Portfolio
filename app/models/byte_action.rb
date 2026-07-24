# Structured request/response record for Byte's interactive prompts.
# Backs three UX flows through a single record shape:
#
#   * permission — Claude Code PreToolUse hook is asking "may I run this
#                  Bash/Write/Edit?"; buttons: Allow, Deny.
#   * plan       — Claude's ExitPlanMode tool; buttons: Approve, Deny;
#                  tool_input carries the plan body for prominent render.
#   * question   — AskUserQuestion (SDK / interactive tool); buttons list
#                  the options; multi_select flags multi-answer questions.
#   * jarvis     — Jarvis wants a clarification ("which room?"); buttons
#                  are the choices; tap fires a new Jarvis command.
#
# The lifecycle is uniform across all four: `pending` → `decided` (user
# tapped) OR `expired` (timeout) OR `aborted` (system killed it).
class ByteAction < ApplicationRecord
  belongs_to :user
  belongs_to :byte_conversation
  belongs_to :byte_message, optional: true

  enum :kind,  { permission: 0, plan: 1, question: 2, jarvis: 3, custom: 4 }
  enum :state, { pending: 0, decided: 1, expired: 2, aborted: 3 }

  scope :active, -> { where(state: :pending).where("expires_at IS NULL OR expires_at > ?", Time.current) }

  # Overall default expiry for a pending action. Long enough for a user
  # to walk back to their phone from another room; short enough that a
  # forgotten action doesn't wedge a Claude turn forever.
  DEFAULT_TTL = 10.minutes

  before_validation on: :create do
    self.request_id ||= SecureRandom.uuid
    self.expires_at ||= DEFAULT_TTL.from_now
  end

  # Payload consumed by the PWA to render an action-request message.
  # Compact + self-describing so the client doesn't need to know the
  # request kind to render it correctly.
  def as_wire
    {
      request_id:   request_id,
      kind:         kind,
      state:        state,
      tool_name:    tool_name,
      tool_input:   tool_input,
      buttons:      buttons,
      multi_select: multi_select,
      decision:     decision,
      expires_at:   expires_at&.iso8601(3),
      decided_at:   decided_at&.iso8601(3),
    }
  end

  # Convenience constructor for callers that want the full "message +
  # action + broadcast" bundle in one call. Used by Jarvis / other
  # in-process senders that don't go through the Mac webhook path.
  #
  # Returns the created ByteAction. The associated message is available
  # via `.byte_message`.
  def self.create_request!(user:, conversation:, kind:, buttons:, title: nil, subtitle: nil, body: nil, tool_name: nil, tool_input: {}, multi_select: false, timeout_seconds: DEFAULT_TTL)
    action = new(
      user:              user,
      byte_conversation: conversation,
      kind:              kind,
      tool_name:         tool_name,
      tool_input:        tool_input,
      buttons:           buttons,
      multi_select:      multi_select,
      expires_at:        timeout_seconds.from_now,
    )
    action.save!

    message = conversation.byte_messages.create!(
      user:         user,
      direction:    :inbound,
      state:        :delivered,
      body:         body.to_s,
      metadata:     {
        kind:               :"action-request",
        action_request_id:  action.request_id,
        action_kind:        kind.to_s,
        action_state:       :pending,
        tool_name:          tool_name,
        tool_input:         tool_input,
        buttons:            buttons,
        multi_select:       multi_select,
        title:              title,
        subtitle:           subtitle,
        expires_at:         action.expires_at.iso8601(3),
      },
      delivered_at: Time.current,
    )
    action.update!(byte_message_id: message.id)

    MonitorChannel.broadcast_to(user, {
      id:      :byte,
      channel: :byte,
      data:    { kind: :message, message: message.as_wire },
    })

    action
  end

  # Record the user's decision. Idempotent — a repeat tap or a race with
  # the timeout marker won't re-write a decided state.
  def apply_decision!(value:, source: :user)
    return false unless pending?

    self.state       = :decided
    self.decided_at  = Time.current
    self.decision    = { value: value, source: source.to_s }
    save!
    byte_message&.tap do |msg|
      merged = (msg.metadata || {}).merge(
        "action_state"    => "decided",
        "action_decision" => decision,
        "action_decided_at" => decided_at.iso8601(3),
      )
      msg.update!(metadata: merged, state: :delivered)
    end
    true
  end
end
