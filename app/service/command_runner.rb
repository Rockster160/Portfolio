class CommandRunner
  include ActionView::Helpers::DateHelper

  def self.run(user, task, msg)
  #   # Pulled from Command Proposal to bypass async
  #   previous_iteration = task.current_iteration
  #   task.user = user # Sets the task user to assign as the requester
  #   # Creates a new iteration with the same code so we don't lose results
  #   task.update(code: task.code, skip_approval: true)
  #   current_iteration = task.iterations.last
  #   params = args_from_msg(msg) || {}
  #   params.merge!(previous_iteration.attributes.slice("approved_at", "approver_id"))
  #   params.merge!(status: :approved)
  #   current_iteration.update(params.merge(requester: user))
  #
  #   ran = ::CommandProposal::Services::Runner.execute(task.friendly_id)
  #
  #   ran&.result.presence || "No result"
  # rescue CommandProposal::Error => e
  #   e.message
  end

  def self.args_from_msg(msg)
    return if msg.blank?

    args = {}
    delete = []

    arg_names = msg.scan(/\w+\=/)
    msg[/\w+\=.*/].to_s.split(/\w+\=/).each_with_index do |argv, idx|
      next if idx == 0

      arg_name = arg_names[idx-1]
      args[arg_name[0..-2]] = argv.squish
      delete << "#{arg_name}=#{argv}"
    end

    delete.each do |del|
      msg.gsub!(del, "")
    end

    args
  end
end
