module Buddy
  # The routines panel in the Byte drawer: see what's saved, build one, rename
  # one, turn one off, delete one.
  #
  # Writing steps used to be conversation-only, on the grounds that a tool call
  # with validated arguments is a bad thing to type into a text box. The box was
  # the problem, not the UI: the registry already declares every tool's
  # arguments, their types and which are required, so a form built FROM the
  # registry can only offer arguments that exist, and `Buddy::Routines.sanitize`
  # - the same check a routine Byte saves goes through, including each tool's own
  # `confirm` - is what decides whether a step is real. Nothing here composes a
  # step by hand.
  #
  # `update` still refuses `steps`, because #steps owns them and on tighter
  # terms.
  class RoutinesController < ApplicationController
    before_action :authorize_user
    before_action :authorize_owner

    # High enough that nobody hits it on purpose, low enough that a stuck finger
    # on the stepper can't cash in two hundred waters.
    MAX_STEP_COUNT = 20

    # The argument types a field can hold. See `offerable?`.
    FIELD_TYPES = %i[string integer enum boolean iso_time duration_min].freeze

    # What a synthesized duration field says it is for, replacing the pair of
    # descriptions it stands in for - both of which are about which of the two
    # arguments to use, a question the form has already answered.
    DURATION_SAID = "How long the countdown runs.".freeze

    # An integer argument NAMED for its unit is a length too, whatever its type
    # says - `break_minutes`, `every_minutes`. The name is the declaration, and
    # treating them as plain numbers left "10" meaning minutes in one box and
    # seconds in the one above it.
    UNIT_NAMES = { /_minutes\z/ => :minutes, /_seconds\z/ => :seconds }.freeze

    # The tool's OWN length, as opposed to one named for something narrower.
    # See `ranked`.
    PRIMARY_DURATIONS = %i[seconds minutes duration].freeze

    def index
      render json: { routines: current_user.buddy_routines.ordered.map(&:serialize_for_client) }
    end

    # Jil automations that can be turned into a one-tap button.
    #
    # `plain_scopes` is the filter that matters: a listener with data filters on
    # it needs a payload constructed to fire, and there's nowhere on a button to
    # say what that payload is. Offering one would produce a button that looks
    # fine and quietly never fires - the exact failure a saved button must not
    # have. Those stay conversational, where Buddy can ask for the missing bit.
    #
    # Ones already wrapped are left out so the list is what you can still ADD.
    def jil_actions
      render json: { actions: addable_actions }
    end

    # Wrap one as a single-step routine.
    #
    # A Jil button IS a routine with one `trigger_jil_task` step - same record,
    # same runner, same pin/order/on-off/delete, same rendering on the Quick
    # grid and the wall. This is only here because getting one used to mean
    # asking Buddy to save it, and there's nothing to discuss when the whole
    # routine is "fire this".
    # What a step can be MADE of: the tool registry, minus everything a routine
    # can't replay (`routinable: false` - anything whose whole value is one
    # particular moment), with each tool's arguments as the form to fill in.
    #
    # Sent as the schema rather than rendered server-side, because the step
    # builder is a live form - picking a tool repaints the fields under it.
    def tools
      render json: { tools: composable_tools }
    end

    def create
      return create_from_steps if params[:steps].present?

      task = firable_tasks.find_by(id: params[:task_id])
      return fail_with("that automation isn't available") if task.nil?

      name = params[:name].to_s.strip.presence || task.name
      return fail_with("you already have one called \"#{name}\"") if named_already?(name)

      routine = build_jil_routine(task, name)
      return fail_with(*routine.errors.full_messages) unless routine.save

      render json: routine.serialize_for_client, status: :created
    rescue StandardError => e
      render json: { errors: [e.message] }, status: :unprocessable_entity
    end

    def update
      if routine.update(routine_params)
        render json: routine.serialize_for_client
      else
        render json: { errors: routine.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # The whole step list, in the order it should end up in. A row is either one
    # already saved, named by its ORIGINAL index, or a new one carrying a
    # `tool_name` and a payload - so this prunes, reorders, re-counts and adds.
    #
    # A kept step rides through exactly as it was stored and is never re-checked
    # against the live registry here. That matters: `sanitize` asks each tool's
    # `confirm` whether the name still resolves, so running kept steps back
    # through it would let a routine that has gone stale - a renamed chore, a
    # deleted task - refuse the reorder that has nothing to do with it.
    #
    # Count is the one value editable in place on a kept step, because it's the
    # one that's purely a number and the one that's most often wrong - "cup
    # water" was saved to cash in three and read back as one for days.
    def steps
      rebuilt = rebuilt_steps
      return render(json: { errors: ["a routine needs at least one step"] }, status: :unprocessable_entity) if rebuilt.empty?

      if routine.update(steps: rebuilt)
        render json: routine.serialize_for_client
      else
        render json: { errors: routine.errors.full_messages }, status: :unprocessable_entity
      end
    rescue StandardError => e
      render json: { errors: [e.message] }, status: :unprocessable_entity
    end

    def destroy
      routine.destroy!
      head :no_content
    end

    # Tap on the Quick grid. Runs deterministically with no model turn - see
    # Buddy::Routines.run! - so it costs nothing and does the same thing twice.
    def run
      run_routine = runnable_routine
      return render(json: { error: "routine not found" }, status: :not_found) if run_routine.nil?
      unless run_routine.enabled?
        return render(json: { error: "that routine is turned off" }, status: :unprocessable_entity)
      end

      conversation = runnable_conversation
      return render(json: { error: "conversation not found" }, status: :not_found) if conversation.nil?

      Buddy::Routines.run!(run_routine, conversation: conversation)
      render json: run_routine.serialize_for_client
    end

    # Whole-grid reorder in one request. The client sends the pinned ids in the
    # order it just dropped them into, and every position is rewritten from that
    # - a per-row PATCH would leave the grid half-reordered if one of them
    # failed, and the order is a single fact rather than N independent ones.
    #
    # Anything omitted is unpinned, so this is also how the last one comes off
    # the grid.
    def reorder
      ids = Array(params[:ids]).map(&:to_i).uniq.select(&:positive?)
      mine = current_user.buddy_routines.where(id: ids).index_by(&:id)

      # Validation is skipped deliberately. `steps_are_runnable` re-checks every
      # step against the live tool registry, which is right when the steps
      # change and pure cost when only a grid position does — and it would let a
      # routine that has gone stale block a reorder that has nothing to do with
      # it.
      BuddyRoutine.transaction {
        # rubocop:disable Rails/SkipsModelValidations
        current_user.buddy_routines.pinned.where.not(id: ids).update_all(position: nil)
        ids.each_with_index { |id, i| mine[id]&.update_column(:position, i) }
        # rubocop:enable Rails/SkipsModelValidations
      }

      render json: { routines: current_user.buddy_routines.ordered.map(&:serialize_for_client) }
    end

    private

    def authorize_owner
      head :forbidden unless current_user&.byte_access?
    end

    def routine
      @routine ||= current_user.buddy_routines.find(params[:id])
    end

    # The routine a press may run: your own, or a household member's reached from
    # their shared board. Buddy::Routines.run! fires routine.user's markers, so a
    # shared trigger keeps the OWNER's reach by construction, with no acting-user
    # to thread. Kept apart from `routine` above, which stays owner-only — destroy
    # and update must never widen to the household.
    def runnable_routine
      own = current_user.buddy_routines.find_by(id: params[:id])
      return own if own
      return nil if current_user.chore_household_id.nil?

      BuddyRoutine.where(user_id: current_user.chore_household_user_ids).find_by(id: params[:id])
    end

    # The board or thread the run happens on: your own, or a household member's
    # shared board. It only sets which pet the cheer lands on.
    def runnable_conversation
      current_user.byte_conversations.buddy.active.find_by(id: params[:conversation_id]) ||
        ByteConversation.accessible_boards_for(current_user).find_by(id: params[:conversation_id])
    end

    def firable_tasks
      current_user.accessible_tasks.buddy_visible.plain_scopes
    end

    def addable_actions
      taken = wrapped_task_names
      firable_tasks.order(:name).limit(300).filter_map { |t|
        next nil if taken.include?(t.name.to_s.downcase)

        { id: t.id, name: t.name, description: t.description.to_s.strip.presence, scope: t.listener.to_s.strip }.compact
      }
    end

    # Which tasks already have a button. Read off the steps rather than tracked
    # separately, so a routine deleted by hand frees its task back up with
    # nothing to keep in sync.
    def wrapped_task_names
      current_user.buddy_routines.pluck(:steps).flatten.filter_map { |step|
        next nil unless step.is_a?(Hash) && step["tool_name"].to_s == "trigger_jil_task"

        step.dig("payload", "name").to_s.downcase.presence
      }.to_set
    end

    # Through Buddy::Routines.sanitize rather than hand-built, so a button made
    # here is checked by exactly what checks one Buddy saves - including the
    # tool's own confirm, which is what proves the name still resolves to a task
    # that exists.
    def build_jil_routine(task, name)
      steps = Buddy::Routines.sanitize(
        [{ "tool_name" => "trigger_jil_task", "payload" => { "name" => task.name } }],
        Buddy::ToolContext.new(current_user),
      )
      current_user.buddy_routines.new(name: name, description: task.description.to_s.strip.presence, steps: steps)
    end

    # The final list, in the order asked for.
    #
    # An index that isn't there is dropped rather than erroring: the panel and
    # the record can be a moment apart, and a step that has already gone is the
    # outcome either way. Each index is taken once - two of the same is a
    # dragging glitch, not a request for the step twice - and that de-duping
    # deliberately does NOT apply to new rows, which have no index and of which
    # two identical ones is a perfectly reasonable thing to want.
    def rebuilt_steps
      current = Array(routine.steps)
      taken   = Set.new

      Array(params[:steps]).filter_map { |raw|
        next composed_step(raw) if raw[:tool_name].present?

        index = raw[:index].to_i
        next nil unless taken.add?(index)

        step = current[index]
        step && recounted(step, raw[:count])
      }
    end

    # A step the panel just built, through exactly what checks one Byte saves -
    # the registry for the arguments, then the tool's own `confirm` for whether
    # the names in them resolve to anything. A step that fails says why in the
    # tool's own words, which is a better sentence than this could write.
    def composed_step(raw)
      Buddy::Routines.sanitize_step(
        raw.to_unsafe_h, (raw[:position].presence || 1).to_i, Buddy::ToolContext.new(current_user)
      )
    end

    def create_from_steps
      name = params[:name].to_s.strip
      return fail_with("a routine needs a name") if name.blank?
      return fail_with("you already have one called \"#{name}\"") if named_already?(name)

      routine = current_user.buddy_routines.new(
        name:        name,
        description: params[:description].to_s.strip.presence,
        steps:       Buddy::Routines.sanitize(params[:steps].map(&:to_unsafe_h), Buddy::ToolContext.new(current_user)),
      )
      return fail_with(*routine.errors.full_messages) unless routine.save

      render json: routine.serialize_for_client, status: :created
    end

    def named_already?(name)
      current_user.buddy_routines.exists?(["LOWER(name) = ?", name.downcase])
    end

    def fail_with(*messages)
      render json: { errors: messages }, status: :unprocessable_entity
    end

    def composable_tools
      Buddy::Tools.all.select { |tool| offerable?(tool) }.map { |tool|
        {
          name:        tool[:name],
          label:       tool[:name].to_s.tr("_", " "),
          description: blurb(tool),
          args:        fields_for(tool),
        }
      }
    end

    # A tool the panel can actually offer. Beyond `routinable?`, every REQUIRED
    # argument has to be something a field can hold: an `:object` arg is a shape
    # rather than a value - the only one is a prompt's question-to-answer map -
    # and a text box asking for it would be a step that looks filled in and
    # fails. Those stay conversational, the way a Jil task with data filters on
    # its listener does.
    def offerable?(tool)
      return false unless Buddy::Tools.routinable?(tool)

      tool[:args].to_h.none? { |_key, spec| spec[:required] && FIELD_TYPES.exclude?(spec[:type]) }
    end

    # A DURATION IS ONE FIELD, however the tool takes it.
    #
    # `seconds` and `minutes` are separate arguments because the model picks
    # whichever matches how it was said. A person filling in a form has one
    # duration and no reason to care which box it belongs in - offered raw it
    # was two empty fields, either of which might be the wrong one, under a hint
    # explaining to use one and not the other.
    #
    # The field takes the shorthand the rest of the app takes (`4m`, `4m30s`,
    # `1h30m`, `4:30`, or a bare number of seconds) and the client converts it
    # to whichever unit the argument wants.
    def fields_for(tool)
      args   = tool[:args].to_h.select { |_key, spec| FIELD_TYPES.include?(spec[:type]) }
      paired = args.key?(:seconds) && args.key?(:minutes)
      args   = args.except(:minutes) if paired

      ranked(args.map { |key, spec| arg_schema(key, spec, paired: paired && key == :seconds) })
    end

    def unit_for(key, spec, paired)
      return :seconds if paired
      return :minutes if spec[:type] == :duration_min

      UNIT_NAMES.find { |pattern, _unit| key.to_s.match?(pattern) }&.last if spec[:type] == :integer
    end

    # Required first and on screen, everything else folded away.
    #
    # A tool's arguments are its whole surface to the model, and that is a lot
    # more than a person setting one up has to decide: `set_timer` takes ten, six
    # of them about a repeating work/break rhythm with a stop condition. Asked
    # all at once it reads as ten decisions rather than one.
    #
    # The tool's OWN length is primary whatever it says about it, because on
    # anything that has one it IS the question. A length named for something
    # narrower is not: `break_minutes` is about a work/break rhythm and
    # `every_minutes` about repeating within a day, and both only mean anything
    # once a switch below has been turned on.
    #
    # When nothing is primary there is nothing to fold behind, so it all shows
    # rather than hiding an entire form.
    def ranked(fields)
      primary = fields.select { |field| field[:required] || main_length?(field) }
      return fields if primary.empty?

      fields.map { |field| primary.include?(field) ? field : field.merge(advanced: true) }
    end

    def main_length?(field)
      field[:type] == :duration && PRIMARY_DURATIONS.include?(field[:key])
    end

    # One line, from the top of the tool's own description. The descriptions are
    # written for the model and run to paragraphs; the first sentence is the one
    # that says what the tool is for, and it is the only part that fits beside a
    # name in a list.
    def blurb(tool)
      first = tool[:description].to_s.split("\n").map(&:strip).find(&:present?)
      first.to_s.delete("*`#").split(/(?<=[.!?])\s/).first.to_s.truncate(140).presence
    end

    # Enough for the panel to draw a field and refuse an empty required one
    # before it ever asks the server. `values` is what makes an enum a select
    # rather than a text box somebody has to guess the spelling into, and `unit`
    # is what a duration gets converted back into.
    def arg_schema(key, spec, paired: false)
      unit = unit_for(key, spec, paired)
      said = paired ? DURATION_SAID : spec[:description]

      {
        key:         key,
        type:        unit ? :duration : spec[:type],
        unit:        unit,
        required:    spec[:required] == true,
        values:      (Array(spec[:values]).map(&:to_s).presence if spec[:type] == :enum),
        description: said.to_s.strip.squish.truncate(180).presence,
      }.compact
    end

    # Only the count moves, and only on a tool that has repeat semantics at all
    # (merge_label is what declares them). Everything else in the payload rides
    # through exactly as saved.
    def recounted(step, count)
      payload = (step["payload"] || {}).dup
      tool    = Buddy::Tools[step["tool_name"].to_s.presence || "-"]
      key     = Buddy::Tools::COUNT_ARG.to_s

      if count.present? && tool && tool[:merge_label]
        times = count.to_i.clamp(1, MAX_STEP_COUNT)
        times > 1 ? payload[key] = times : payload.delete(key)
      end
      BuddyRoutine.step(step["tool_name"], payload)
    end

    # Deliberately no `position`: the grid's order is one fact, so #reorder owns
    # it outright. Pinning is that list plus one, unpinning is it minus one.
    # No `steps` either - #steps owns those, and on tighter terms.
    def routine_params
      permitted = params.require(:routine).permit(:name, :description, :enabled, tags: [])
      if (csv = params.dig(:routine, :tags_csv))
        permitted[:tags] = csv.to_s.split(",").map(&:strip).compact_blank
      end
      permitted
    end
  end
end
