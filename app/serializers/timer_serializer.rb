# == Schema Information
#
# Table name: timers
#
#  id                  :bigint           not null, primary key
#  user_id             :bigint           not null
#  timer_page_id       :bigint
#  name                :text             default(""), not null
#  kind                :integer          default("countdown"), not null
#  color               :text
#  section_id          :integer
#  pos_x               :integer          default(0), not null
#  pos_y               :integer          default(0), not null
#  width               :integer          default(0), not null
#  height              :integer          default(0), not null
#  duration_ms         :bigint
#  started_at          :datetime
#  paused_at           :datetime
#  paused_remaining_ms :bigint
#  end_at              :datetime
#  repeat              :boolean          default(FALSE), not null
#  repeat_count        :integer          default(0), not null
#  require_confirm_tap :boolean          default(FALSE), not null
#  value               :integer          default(0), not null
#  step                :integer          default(1), not null
#  min_value           :integer
#  max_value           :integer
#  reset_value         :integer          default(0), not null
#  dial_config         :jsonb            not null
#  dial_step_index     :integer          default(0), not null
#  callbacks           :jsonb            not null
#  fire_jid            :string
#  fire_scheduled_for  :datetime
#  fired_at            :datetime
#  confirmed_at        :datetime
#  archived_at         :datetime
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  disabled            :boolean          default(FALSE), not null
#
class TimerSerializer
  def initialize(timer, viewer:, share: nil)
    @t = timer
    @viewer = viewer
    @share = share
  end

  def as_json
    base = {
      id:            @t.id,
      kind:          @t.kind,
      name:          @t.name,
      color:         @t.color,
      timer_page_id: @t.timer_page_id,
      section_id:    @t.section_id,
      pos_x:         @t.pos_x,
      pos_y:         @t.pos_y,
      width:         @t.width,
      height:        @t.height,
      disabled:      @t.disabled,
      updated_at:    @t.updated_at.iso8601(3),
    }

    case @t.kind.to_sym
    when :countdown
      base.merge!(
        duration_ms:         @t.duration_ms,
        started_at:          @t.started_at&.iso8601(3),
        paused_at:           @t.paused_at&.iso8601(3),
        end_at:              @t.end_at&.iso8601(3),
        paused_remaining_ms: @t.paused_remaining_ms,
        remaining_ms_now:    @t.remaining_ms,
        repeat:              @t.repeat,
        repeat_count:        @t.repeat_count,
        fired_at:            @t.fired_at&.iso8601(3),
        confirmed_at:        @t.confirmed_at&.iso8601(3),
      )
    when :counter
      base.merge!(
        value:       @t.value,
        step:        @t.step,
        min_value:   @t.min_value,
        max_value:   @t.max_value,
        reset_value: @t.reset_value,
      )
    when :dial
      base.merge!(
        dial_config:     @t.dial_config,
        dial_step_index: @t.dial_step_index,
      )
    end

    # A WAIT chip never rings (see Buddy::Timers::WAIT). The client decides that
    # off `end_at`, seconds before the server's fire arrives, so it has to be
    # here rather than something looked up when the countdown ends.
    base[:wait] = true if @t.countdown? && Buddy::Timers.wait?(@t)

    base[:callbacks] = @t.callbacks unless @share&.view_only?
    base
  end
end
