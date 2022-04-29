class AddSurveyThings < ActiveRecord::Migration[5.0]
  def change
    create_table :surveys do |t|
      t.text :name # "Color Code", "16 personalities", etc...
      t.text :slug
      t.text :description
      t.boolean :randomize_answers, default: true
      # t.integer :score_type, default: :accumulate # aggregate, accumulate

      t.timestamps
    end
    create_table :survey_results do |t|
      t.belongs_to :survey
      t.text :name # "Blue", "INTJ - The Architect", etc////

      t.timestamps
    end
    create_table :survey_result_details do |t|
      t.belongs_to :survey
      t.belongs_to :survey_result
      t.text :description # "Blue personalities are emotional"
      t.integer :value
      t.integer :conditional, default: :full # full, equal, greater, lesser, greater_equal, lesser_equal

      t.timestamps
    end
    create_table :survey_questions do |t|
      t.belongs_to :survey
      t.text :text
      t.integer :position
      t.integer :format, default: :select_one # select_one, select_many, scale
      t.integer :score_split_question, default: :whole # whole, divided
      # ^^ divided takes the points for each multi-select answer and divides them by the number of
      #   answers selected
      # conditional_operator
      # conditional_question
      # conditional_answer
      # conditional_value

      t.timestamps
    end
    create_table :survey_question_answers do |t|
      t.belongs_to :survey
      t.belongs_to :survey_question
      t.text :text
      t.integer :position

      t.timestamps
    end
    create_table :survey_question_answer_results do |t|
      t.belongs_to :survey
      t.belongs_to :survey_result
      t.belongs_to :survey_question
      t.belongs_to :survey_question_answer, index: { name: :index_answer_result_ids }
      t.integer :value

      t.timestamps
    end

    create_table :user_surveys do |t|
      t.belongs_to :user
      t.belongs_to :survey
      t.text :token # Needs to be generated

      t.timestamps
    end
    create_table :user_survey_responses do |t|
      t.belongs_to :user
      t.belongs_to :survey
      t.belongs_to :user_survey
      t.belongs_to :survey_question
      t.belongs_to :survey_question_answer

      t.timestamps
    end
  end
end
