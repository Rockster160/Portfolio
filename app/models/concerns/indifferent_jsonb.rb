# frozen_string_literal: true

module IndifferentJsonb
  extend ActiveSupport::Concern

  class_methods do
    def indifferent_jsonb(*columns)
      columns.each do |col|
        ivar_ref = "@indifferent_#{col}"
        before_save { send("#{col}=", send(col)) }

        define_method(col) do
          ivar = instance_variable_get(ivar_ref)
          return ivar if ivar.present?

          # Need empty parens here since Ruby gets confused and thinks we are passing implicit args
          value = super() || {}
          value = (
            case value
            when Hash then value.with_indifferent_access
            when Array then value.map { |item| item.try(:with_indifferent_access) || item }
            else
              value
            end
          )

          instance_variable_set(ivar_ref, value)
          value
        end

        define_method("#{col}=") do |new_data|
          new_json = JSON.parse(new_data&.to_json || "{}")

          new_json.reverse_merge!(send(col)).compact if new_data.is_a?(Hash)

          instance_variable_set(ivar_ref, nil) # reset ivar to re-pull next time
          super(new_json)
        end
      end
    end
  end
end
