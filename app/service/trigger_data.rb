module TriggerData
  module_function

  def parse(input, as: nil)
    return input if input.is_a?(::ApplicationRecord)

    input = input.permit!.to_h.except(:controller, :action) if input.is_a?(::ActionController::Parameters)
    input = input.to_h if input.is_a?(::ActiveSupport::HashWithIndifferentAccess)

    return unwrap(input.deep_symbolize_keys) if input.is_a?(::Hash)
    return unwrap({ data: input }) if input.is_a?(::Array)

    begin
      return TriggerData.parse(::JSON.parse(input)) if input.is_a?(::String)
    rescue ::JSON::ParserError
      # Might be nested string `something:nested:value`
    end

    return { data: input } unless input.is_a?(::String)
    return { data: input } unless input.match?(/\w+(:\w+)+/)

    TriggerData.parse(input.split(":").reverse.reduce { |value, key| { key.to_sym => value } })
  end

  def unwrap(json, as: nil)
    return json unless json.is_a?(::Hash)

    json.transform_values { |value|
      case value
      when ::Hash then unwrap(value)
      when ::Array then value.map { |v| unwrap(v) }
      when ::String then lookup(value, as: as)
      else value
      end
    }
  end

  def lookup(string, as: nil)
    # "gid://Jarvis/User/1"
    return string unless as.is_a?(::User)
    return string unless string.is_a?(::String)

    _m, klass_name, id = string.match(/\Agid:\/\/Jarvis\/(\w+)\/(\d+)\z/)&.to_a
    return string unless klass_name.present? && id.present?

    klass = klass_name.constantize
    reflection = ::User.reflections.values.find { |r| r.klass == klass }

    me.send(reflection.name).find(id)
  rescue NameError, ::ActiveRecord::RecordNotFound
    string
  end

  def serialize(data, use_global_id: true)
    case data
    when ::Hash then data.transform_values { |value| serialize(value) }
    when ::Array then data.map { |value| serialize(value) }
    when ::ApplicationRecord
      use_global_id ? data.to_global_id.to_s : data.serialize(use_global_id: use_global_id)
    when ::String then data
    else data
    end
  end
end
