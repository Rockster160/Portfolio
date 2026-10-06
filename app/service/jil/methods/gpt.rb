class Jil::Methods::GPT < Jil::Methods::Base
  def cast(value)
    @jil.cast(value, :Hash)
  end

  # [GPT]
  #   #connection("Secret" TAB String)
  #   .ask(Text)::String
  #   .askJson(Text)::Hash
  #   .preset(String:"Preset" BR Text)::String
  #   .presetJson(String:"Preset" BR Text)::Hash

  # Shaped like Oauth.connection: a handle the other calls go through. It holds
  # the secret's NAME only — the key is read at request time, so it never sits
  # in the run's variables or output.
  def connection(secret_name)
    { secret: secret_name }
  end

  def ask(gpt, text)
    request(gpt, text)
  end

  def askJson(gpt, text) # rubocop:disable Naming/MethodName
    request(gpt, text, json: true)
  end

  # A preset's instructions go in as the system message and `text` as the
  # user's, so the saved part steers and the passed part is what it's about.
  def preset(gpt, name, text)
    request(gpt, text, instructions: find_preset(name).instructions)
  end

  def presetJson(gpt, name, text) # rubocop:disable Naming/MethodName
    request(gpt, text, instructions: find_preset(name).instructions, json: true)
  end

  private

  def request(gpt, text, instructions: nil, json: false)
    ::GPTRequest.call(key_for(gpt), text, instructions: instructions, json: json)
  rescue ::GPTRequest::Error => e
    raise ::Jil::ExecutionError, e.message
  end

  def key_for(gpt)
    name = cast(gpt).with_indifferent_access[:secret]
    secret = @jil.user.secrets.named(name)
    raise ::Jil::ExecutionError, "No secret named \"#{name}\" - add it at /jil/secrets" if secret.nil?

    secret.value
  end

  def find_preset(name)
    @jil.user.gpt_presets.named(name) || raise(::Jil::ExecutionError, "No GPT preset named \"#{name}\"")
  end
end
