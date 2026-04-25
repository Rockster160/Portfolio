# == Schema Information
#
# Table name: execution_payloads
#
#  id         :bigint           not null, primary key
#  code       :text
#  ctx        :jsonb
#  input_data :jsonb
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
class ExecutionPayload < ApplicationRecord
  has_one :execution, foreign_key: :payload_id, inverse_of: :payload, dependent: :nullify
end
