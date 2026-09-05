require "sinatra"
require "json"

set :public_folder, File.join(__dir__, "public")
set :views, File.join(__dir__, "views")

# 編集対象として公開するプロジェクトのルートディレクトリ
PROJECT_ROOT = File.expand_path("project", __dir__)

# 編集を許可する拡張子(Ruby / C)
ALLOWED_EXTENSIONS = %w[.rb .c .h].freeze

helpers do
  # path traversal (../ などによる範囲外アクセス) を防ぎつつ絶対パスに変換する
  def safe_path(rel_path)
    full = File.expand_path(File.join(PROJECT_ROOT, rel_path.to_s))
    root_with_sep = PROJECT_ROOT + File::SEPARATOR
    unless full == PROJECT_ROOT || full.start_with?(root_with_sep)
      raise ArgumentError, "invalid path"
    end
    full
  end

  def json_error(status, message)
    halt status, { error: message }.to_json
  end
end

# エディタ画面
get "/" do
  erb :index
end

# 編集可能なファイル一覧を返す
get "/api/files" do
  content_type :json

  files = Dir.glob(File.join(PROJECT_ROOT, "**", "*")).select do |f|
    File.file?(f) && ALLOWED_EXTENSIONS.include?(File.extname(f))
  end

  relative_paths = files.map { |f| f.sub(PROJECT_ROOT + File::SEPARATOR, "") }.sort

  relative_paths.to_json
end

# 指定ファイルの内容を返す
get "/api/file" do
  content_type :json

  rel = params[:path]
  json_error(400, "path is required") if rel.nil? || rel.empty?

  begin
    full = safe_path(rel)
  rescue ArgumentError
    json_error(400, "invalid path")
  end

  json_error(404, "file not found") unless File.file?(full)
  json_error(400, "unsupported file type") unless ALLOWED_EXTENSIONS.include?(File.extname(full))

  { path: rel, content: File.read(full) }.to_json
end

# ファイル内容を保存する
post "/api/file" do
  content_type :json

  payload =
    begin
      JSON.parse(request.body.read)
    rescue JSON::ParserError
      json_error(400, "invalid json body")
    end

  rel = payload["path"]
  content = payload["content"]

  json_error(400, "path is required") if rel.nil? || rel.empty?
  json_error(400, "content is required") if content.nil?

  begin
    full = safe_path(rel)
  rescue ArgumentError
    json_error(400, "invalid path")
  end

  # 既存ファイルの上書きのみ許可(新規ファイル作成はサンプルでは対象外)
  json_error(404, "file not found") unless File.file?(full)
  json_error(400, "unsupported file type") unless ALLOWED_EXTENSIONS.include?(File.extname(full))

  File.write(full, content)

  { status: "ok", path: rel, bytes: content.bytesize }.to_json
end
