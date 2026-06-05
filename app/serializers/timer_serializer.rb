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

    base[:callbacks] = @t.callbacks unless @share&.view_only?
    base
  end
end
