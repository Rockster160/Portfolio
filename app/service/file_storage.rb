module FileStorage
  module_function

  CREDENTIALS = Aws::Credentials.new(
    ENV.fetch("PORTFOLIO_S3_ACCESS_KEY", nil),
    ENV.fetch("PORTFOLIO_S3_SECRET_KEY", nil),
  )
  DEFAULT_REGION = "us-east-1".freeze
  DEFAULT_BUCKET = "ardesian-storage".freeze
  TMP_DIR = Rails.root.join("tmp/file_storage")

  def mode=(new_mode)
    @mode = new_mode.to_sym
  end

  def mode(new_mode=:_unused_without_block, &block)
    if block_given?
      if new_mode == :_unused_without_block
        raise ArgumentError, "Must set a mode when calling with a block"
      end

      previous_mode = @mode
      @mode = new_mode
      result = block.call
      @mode = previous_mode
      return result
    end

    return @mode if defined?(@mode) && @mode.present?

    @mode ||= ENV["FILE_STORAGE_MODE"].presence&.to_sym
    @mode ||= :s3 if ::Rails.env.production?
    @mode ||= :local if ::Rails.env.development?
    return @mode if @mode.present?

    raise "FILE_STORAGE_MODE is not set"
  end

  def s3(filename, string_data=:_no_value_passed, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
    if string_data == :_no_value_passed
      download(filename, bucket: bucket, region: region) if exists?(filename, bucket: bucket, region: region)
    elsif string_data.nil?
      delete(filename, bucket: bucket, region: region)
    else
      upload(string_data, filename: filename, bucket: bucket, region: region)
    end
  end

  def upload(file_data, filename: nil, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION, options: {})
    filename ||= "file-#{Time.current.strftime("%Y-%m-%d-%H-%M-%S")}"

    case mode
    when :s3
      s3_object(filename, bucket: bucket, region: region).put(body: file_data, **options)
    else
      FileUtils.mkdir_p("#{TMP_DIR}/#{bucket}")
      File.binwrite(local_path_for(filename, bucket: bucket), file_data)
    end
  end

  def download(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
    case mode
    when :s3
      s3_object(filename, bucket: bucket, region: region).get.body.read
    else
      File.binread(local_path_for(filename, bucket: bucket))
    end
  end

  def exists?(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
    case mode
    when :s3
      s3_object(filename, bucket: bucket, region: region).exists?
    else
      File.exist?(local_path_for(filename, bucket: bucket))
    end
  end

  def delete(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
    case mode
    when :s3
      s3_object(filename, bucket: bucket, region: region).delete
    else
      FileUtils.rm_f(local_path_for(filename, bucket: bucket))
    end
  end

  def public_url(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
    case mode
    when :s3
      s3_object(filename, bucket: bucket, region: region).public_url
    else
      local_path_for(filename, bucket: bucket).to_s
    end
  end

  def expiring_url(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION, expires_in: 1.hour.to_i)
    case mode
    when :s3
      s3_object(filename, bucket: bucket, region: region).presigned_url(:get, expires_in: expires_in)
    else
      public_url(filename, bucket: bucket, region: region)
    end
  end

  def get_or_upload(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION, &block)
    return expiring_url(filename, bucket: bucket, region: region) if exists?(filename, bucket: bucket, region: region)

    data = block.call
    upload(data, filename: filename, bucket: bucket, region: region)
    expiring_url(filename, bucket: bucket, region: region)
  end

  def s3_object(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
    options = { region: region, credentials: CREDENTIALS }
    options[:http_wire_trace] = false
    options[:ssl_verify_peer] = false unless ::Rails.env.production?

    ::Aws::S3::Resource.new(**options).bucket(bucket).object(filename.to_s)
  end

  def local_path_for(filename, bucket: DEFAULT_BUCKET)
    TMP_DIR.join(bucket, ::Digest::SHA1.hexdigest(filename.to_s.tr("/", "_")))
  end
end
