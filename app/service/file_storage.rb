module FileStorage
  module_function

  CREDENTIALS = Aws::Credentials.new(ENV["PORTFOLIO_S3_ACCESS_KEY"], ENV["PORTFOLIO_S3_SECRET_KEY"])
  DEFAULT_REGION = "us-east-1"
  DEFAULT_BUCKET = "ardesian-storage"

  def object(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
    Aws::S3::Resource.new(region: region, credentials: CREDENTIALS)
      .bucket(bucket)
      .object(filename)
  end

  def upload(file_data, filename: nil, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
    filename = filename || "file-#{Time.current.strftime("%Y-%m-%d-%H-%M-%S")}"
    object(filename).tap { |f|
      f.put(body: file_data)
    }
  end

  def download(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
    object(filename, bucket: bucket, region: region)
      .get
      .body
      .read
  end

  def soft_get(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
    obj = object(filename, bucket: bucket, region: region)

    obj.get.body.read if obj.exists?
  end

  def get_or_upload(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION, &block)
    FileStorage.soft_get(filename, bucket: bucket, region: region)
      &.tap { |f| return f.presigned_url(:get, expires_in: 1.hour.to_i) }

    data = block.call
    FileStorage.upload(data, filename: filename, bucket: bucket, region: region)
      .presigned_url(:get, expires_in: 1.hour.to_i)
  end

  def delete(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
    object(filename, bucket: bucket, region: region)
      .delete
  end

  def exists?(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
    object(filename, bucket: bucket, region: region)
      .exists?
  end

  def expiring_url(filename, bucket: DEFAULT_BUCKET, region: DEFAULT_REGION)
    object(filename, bucket: bucket, region: region)
      .presigned_url(:get, expires_in: 1.hour.to_i)
  end
end
