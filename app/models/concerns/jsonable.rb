# frozen_string_literal: true

module Jsonable
  extend ::ActiveSupport::Concern

  included do
    class << self
      def json_attributes(*attrs)
        attrs.each { |attr| attribute attr, SymbolizedJsonFormatter }
      end

      # where_json_key(raw: [:author, :email])
      def where_json_key(hash)
        chaining { |c|
          hash.each do |key, value|
            c.where("jsonb_path_exists(#{table_name}.#{key}::jsonb, '$.#{Array.wrap(value).join(".")}')")
          end
        }
      end

      # where_json_value(metadata: { google_drive_id: "abcd1234" })
      def where_json_value(hash)
        chaining { |c|
          hash.each do |key, value|
            c.where("#{table_name}.#{key}::jsonb @> ?", value.to_json)
          end
        }
      end
    end
  end
end
