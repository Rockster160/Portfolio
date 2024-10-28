module ExceptionNotifier
  class CustomNotifier
    def initialize(options)
    end

    def call(exception, options={})
      exception_name = "#{exception.class.to_s =~ /^[aeiou]/i ? "An" : "A"} `#{exception.class.to_s}`"

      if options[:env].nil?
        text = "#{exception_name} occurred in background\n"
      else
        env = options[:env]
        data = (env["exception_notifier.exception_data"] || {}).merge(options[:data] || {})
        kontroller = env["action_controller.instance"]
        request = env["action_dispatch.request"]
        if data[:current_user]
          text = "*#{data[:current_user].try(:username)}* experienced #{exception_name}"
        else
          text = "[#{request&.ip || "?.?.?.?"}] #{exception_name} occurred"
        end
        text += " from `#{env["REQUEST_METHOD"]} <#{env["REQUEST_URI"]}>`"
        if kontroller
          text += " was processed by `#{kontroller.controller_name}##{kontroller.action_name}`"
        end
        params = data[:params] || request&.params
        if params
          params = params.permit!.to_h if params.is_a?(::ActionController::Parameters)
          begin
            text += "\n```\n#{JSON.pretty_generate(params)}\n```\n"
          rescue StandardError
            str = "#{params}".truncate(2000)
            text += "\n```\n#{str}\n```\n"
          end
        end
      end

      clean_message = exception.message.gsub("`", "'")
      fields = [{ title: "Exception", value: clean_message }]

      focused_backtrace = focused_trace(exception.backtrace).presence
      if focused_backtrace
        fields.push({ title: "Focused Backtrace", value: focused_backtrace.join("\n") })
      else
        fields.push({ title: "Focused Caller", value: focused_trace(caller).join("\n") })
      end

      exception_message = fields.map { |h| "*#{h[:title]}*\n#{h[:value]}" }.join("\n\n")
      attchs = [color: "danger", text: exception_message, mrkdwn_in: %w(text fields)]

      environ = Rails.env.production? ? "*[PROD]*" : "_[#{Rails.env.upcase}]_"
      ::SlackNotifier.notify(text, channel: "#portfolio", username: "Portfolio-Bot#{environ}", icon_emoji: ":blackmage::", attachments: attchs)
    end

    def focused_trace(trace, before: 10, after: 5)
      return [] if !trace

      trace.select { |line|
        line.to_s.include?(Rails.root.to_s)
      }.map { |line|
        line.gsub(/^.*?#{Rails.root}/, "").gsub(/(app)?\/app\//, "app/").gsub(":in `", " `").gsub(/(:\d+) .*?$/, '\1')
      }.then { |list|
        if list.length > (before + after + 1)
          list[..before] + ["..."] + list[-after..]
        else
          list
        end
      }
    end
  end
end
