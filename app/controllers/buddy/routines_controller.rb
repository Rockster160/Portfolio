module Buddy
  # The routines panel in the Byte drawer: see what's saved, rename one, turn
  # one off, delete one. Creating and editing STEPS happens by talking to Byte
  # (`save_routine`), because the steps are tool calls with validated arguments
  # and a text box is a poor way to write those - so this deliberately doesn't
  # take `steps`.
  class RoutinesController < ApplicationController
    before_action :authorize_user
    before_action :authorize_owner

    # High enough that nobody hits it on purpose, low enough that a stuck finger
    # on the stepper can't cash in two hundred waters.
    MAX_STEP_COUNT = 20

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
    def create
      task = firable_tasks.find_by(id: params[:task_id])
      return render(json: { errors: ["that automation isn't available"] }, status: :unprocessable_entity) if task.nil?

      name = params[:name].to_s.strip.presence || task.name
      if current_user.buddy_routines.exists?(["LOWER(name) = ?", name.downcase])
        return render(json: { errors: ["you already have one called \"#{name}\""] }, status: :unprocessable_entity)
      end

      routine = build_jil_routine(task, name)
      if routine.save
        render json: routine.serialize_for_client, status: :created
      else
        render json: { errors: routine.errors.full_messages }, status: :unprocessable_entity
      end
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

    # Prune, reorder, and re-count the steps that are already there.
    #
    # The client sends the ORIGINAL index of each step it's keeping, in the
    # order it wants them, so it never composes a step of its own - it can only
    # rearrange ones that were validated when they were saved. That's the whole
    # reason `update` still refuses `steps`: a tool call written into a text box
    # is a routine that looks fine and fails at 6am.
    #
    # Count is the one value editable in place, because it's the one that's
    # purely a number and the one that's most often wrong - "cup water" was
    # saved to cash in three and read back as one for days.
    def steps
      rebuilt = rebuilt_steps
      return render(json: { errors: ["a routine needs at least one step"] }, status: :unprocessable_entity) if rebuilt.empty?

      if routine.update(steps: rebuilt)
        render json: routine.serialize_for_client
      else
        render json: { errors: routine.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def destroy
      routine.destroy!
      head :no_content
    end

    # Tap on the Quick grid. Runs deterministically with no model turn - see
    # Buddy::Routines.run! - so it costs nothing and does the same thing twice.
    def run
      return render(json: { error: "that routine is turned off" }, status: :unprocessable_entity) unless routine.enabled?

      conversation = current_user.byte_conversations.buddy.active.find_by(id: params[:conversation_id])
      return render(json: { error: "conversation not found" }, status: :not_found) if conversation.nil?

      Buddy::Routines.run!(routine, conversation: conversation)
      render json: routine.serialize_for_client
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

    # Kept steps, in the order asked for. An index that isn't there is dropped
    # rather than erroring: the panel and the record can be a moment apart, and
    # a step that has already gone is the outcome either way.
    #
    # `uniq` because this reorders and prunes - it doesn't add. Two of the same
    # index is a dragging glitch, not a request for the step twice.
    def rebuilt_steps
      current = Array(routine.steps)
      Array(params[:steps]).uniq { |raw| raw[:index].to_i }.filter_map { |raw|
        step = current[raw[:index].to_i]
        step && recounted(step, raw[:count])
      }
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
      params.require(:routine).permit(:name, :description, :enabled)
    end
  end
end
