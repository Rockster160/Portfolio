# {
#   survey: {
#     name: "",
#     description: "",
#     results: [
#       {
#         name: "",
#         details: [
#           {
#             description: "",
#             value: "",
#             conditional: "",
#           }
#         ],
#       },
#     ],
#     questions: [
#       {
#         text: "",
#         answers: [
#           {
#             text: "",
#             results: [
#               { name: "", value: 1 },
#             ]
#           }
#         ]
#       }
#     ],
#   }
# }

class SurveyJsonUploader
  def self.parse(json)
    new.parse(json)
  end

  def parse(json)
    @json = json

    create_everything
  end

  private

  def survey_data
    @survey_data ||= @json[:survey]
  end

  def survey
    @survey ||= create(Survey, survey_data)
  end

  def create(klass, data)
    cols = klass.column_names.map(&:to_sym).select { |col|
      [:id, :created_at, :updated_at].exclude?(col)
    }

    klass.create!(data.slice(*cols))
  rescue ActiveRecord::RecordInvalid => e
    puts "\e[33m[LOGIT] | Error creating #{klass}: \nError: #{e.inspect}\n#{JSON.pretty_generate(data)}\e[0m"
  end

  def create_everything
    create_results
    create_questions
  end

  def create_results
    @results = {}
    survey_data[:results]&.each do |result_data|
      result = create(survey.survey_results, result_data)
      result_data[:details]&.each do |detail_data|
        detail_data[:survey_id] = survey.id
        create(result.survey_result_details, detail_data)
      end

      @results[result.name] = result.id
    end
  end

  def create_questions
    survey_data[:questions]&.each do |question_data|
      question = create(survey.survey_questions, question_data)

      question_data[:answers]&.each do |answer_data|
        answer_data[:survey_id] = survey.id
        answer = create(question.survey_question_answers, answer_data)

        answer_data[:results]&.each do |result_data|
          result_data[:survey_id] = survey.id
          result_data[:survey_question_id] = question.id
          result_data[:survey_result_id] = @results[result_data[:name]]
          create(answer.survey_question_answer_results, result_data)
        end
      end
    end
  end
end
