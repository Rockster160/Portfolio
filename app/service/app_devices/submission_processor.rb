module AppDevices
  # One thing the phone app queued — a command, a Buddy message, a trigger, a
  # task press, a list tick, an answer — received and carried out exactly once.
  #
  # The app retries until it hears back, so the same item can arrive several
  # times (a response lost on the way back looks like a failure to the phone).
  # The item's own uuid is the identity: the second arrival gets the first one's
  # result and does nothing.
  class SubmissionProcessor
    # A press older than this is filed at the time it happened but never
    # stamped onto a Buddy message, which orders its thread by creation time.
    MESSAGE_BACKDATE_LIMIT = 1.day

    def self.call(**)
      new(**).call
    end

    def initialize(device:, params:)
      @device = device
      @user = device.user
      @params = params.to_h.deep_symbolize_keys
    end

    # Returns [submission, duplicate?].
    def call
      existing = AppDeviceSubmission.find_by(uuid: uuid)
      return [existing, true] if existing

      submission = create_submission
      return [AppDeviceSubmission.find_by!(uuid: uuid), true] if submission.nil?

      process(submission)
      [submission, false]
    end

    private

    attr_reader :device, :user, :params

    def uuid = params[:id].to_s.downcase
    def kind = params[:kind].to_s
    def key = params[:key].to_s.presence
    def text = params[:text].to_s.strip.presence
    def data = params[:data].is_a?(Hash) ? params[:data] : {}

    def pressed_at
      @pressed_at ||= (Time.zone.parse(params[:pressed_at].to_s) rescue nil) || Time.current
    end

    # Two copies racing each other meet at the unique index; the loser reports
    # the winner's row.
    def create_submission
      AppDeviceSubmission.create!(
        app_device: device,
        user:       user,
        uuid:       uuid,
        kind:       kind,
        key:        key,
        text:       text,
        data:       data,
        pressed_at: pressed_at,
        source:     params[:source].to_s.presence,
      )
    rescue ActiveRecord::RecordNotUnique
      nil
    end

    def process(submission)
      response = Time.use_zone(params[:timezone].presence || user.timezone) {
        case kind.to_sym
        when :command then run_command
        when :buddy then send_buddy(submission)
        when :trigger then fire_trigger
        when :task then run_task
        when :routine then run_routine
        when :list_toggle then toggle_list
        when :answer then answer
        end
      }
      submission.update!(
        status:       :processed,
        response:     response.presence,
        processed_at: Time.current,
      )
    rescue StandardError => e
      error = "#{e.class}: #{e.message}"
      Rails.logger.warn("[APP_DEVICE] submission #{uuid} (#{kind}) failed: #{error}")
      submission.update!(status: :failed, error: error.first(500), processed_at: Time.current)
    end

    def base_data
      {
        pressed_at: pressed_at.iso8601,
        device:     device.name,
        device_id:  device.id,
        source:     params[:source].to_s.presence,
      }.compact
    end

    def trigger!(scope, payload)
      ::Jil.trigger(user, scope, payload, auth: :trigger, auth_id: user.id)
    end

    def run_command
      raise ArgumentError, "a command needs words" if text.blank?

      trigger!(:ios_command, base_data.merge(text: text))
      result = ::Jarvis.command(user, text, at: pressed_at)
      Array.wrap(result).first.to_s
    end

    def send_buddy(submission)
      signed_ids = Array(data[:attachment_signed_ids]).map(&:to_s).compact_blank
      raise ArgumentError, "a message needs words or a photo" if text.blank? && signed_ids.empty?

      conversation = conversation_for_buddy
      raise ArgumentError, "there is no Buddy conversation to send to" if conversation.nil?

      created = pressed_at > MESSAGE_BACKDATE_LIMIT.ago ? pressed_at : Time.current
      message = ::ByteMessageIntake.call(
        user:                  user,
        conversation:          conversation,
        body:                  text.to_s,
        metadata:              { source: params[:source].presence || :ios, local_id: uuid },
        created_at:            created,
        attachment_signed_ids: signed_ids,
      )
      raise ArgumentError, "the message was refused" if message.nil?

      submission.update!(message_id: message.id)
      nil
    end

    def conversation_for_buddy
      requested = data[:conversation_id].presence
      found = user.byte_conversations.active.find_by(id: requested) if requested
      found || ::ByteConversation.primary_for(user)
    end

    def fire_trigger
      scope = key.to_s.strip
      raise ArgumentError, "a trigger needs a key" if scope.blank?

      changes = batch? ? Array(data[:changes]).select { |change| change.is_a?(Hash) } : [data]
      changes.each { |change|
        payload = DeviceData.call(device: device, key: scope, data: change, pressed_at: pressed_at)
        trigger!(scope, payload.merge(base_data))
      }
      batch? ? "Sent #{changes.length} #{scope}" : "Sent #{scope}"
    end

    # A first sync of a whole address book arrives in batches; each change is
    # still its own landing and its own trigger, as if it had come alone.
    def batch?
      data[:action].to_s == "batch"
    end

    def run_task
      task = user.accessible_tasks.find_by(id: key) || user.accessible_tasks.find_by(uuid: key)
      raise ArgumentError, "no task #{key}" if task.nil?

      run_as = task.user_id == user.id ? user : task.user
      ::Jil::Executor.async_call(
        run_as,
        task.code,
        data.merge(base_data),
        task:    task,
        auth:    :run,
        auth_id: user.id,
      )
      "Running #{task.name}"
    end

    def run_routine
      routine = user.buddy_routines.find_by(id: key)
      if routine.nil? && user.chore_household_id.present?
        routine = ::BuddyRoutine.where(user_id: user.chore_household_user_ids).find_by(id: key)
      end
      raise ArgumentError, "no routine #{key}" if routine.nil?
      raise ArgumentError, "#{routine.name} is turned off" unless routine.enabled?

      conversation = ::ByteConversation.primary_for(user)
      raise ArgumentError, "there is no Buddy conversation to run it in" if conversation.nil?

      ::Buddy::Routines.run!(routine, conversation: conversation)
      "Ran #{routine.name}"
    end

    def toggle_list
      list = user.lists.find_by(id: key) || user.lists.by_param(key).take
      raise ArgumentError, "no list #{key}" if list.nil?

      if data[:item_id].blank?
        raise ArgumentError, "nothing to add" if text.blank?

        list.list_items.add(text)
        return "Added #{text} to #{list.name}"
      end

      item = list.list_items.with_deleted.find(data[:item_id])
      was_deleted = item.deleted?
      checked = !was_deleted
      checked = ::ActiveModel::Type::Boolean.new.cast(data[:checked]) if data.key?(:checked)
      item.checked = checked
      unless was_deleted == item.deleted?
        item.notify_jil(item.deleted? ? :removed : :added)
      end
      "#{item.deleted? ? "Checked" : "Unchecked"} #{item.name}"
    end

    def answer
      reply = Answer.call(user: user, data: data)
      trigger!(:ios_notification_action, data.merge(base_data).merge(result: reply))
      reply
    end
  end
end
