require "sinatra"
require "json"

set :public_folder, File.join(__dir__, "public")
set :views, File.join(__dir__, "views")

# 編集対象として公開するプロジェクト群のルートディレクトリ。
# 直下の各ディレクトリ(例: projects/sample)がそれぞれ独立した編集対象になる。
PROJECTS_ROOT = File.expand_path("../projects", __dir__)

# Funicular(PicoRuby.wasm)版フロントエンドの置き場所
FUNICULAR_ROOT = File.expand_path("funicular", __dir__)

# 編集を許可する拡張子(Ruby / C)
ALLOWED_EXTENSIONS = %w[.rb .c .h].freeze

helpers do
  # PROJECTS_ROOT 直下にあるディレクトリ名(= プロジェクト名)の一覧
  def available_projects
    Dir.children(PROJECTS_ROOT).select { |name| File.directory?(File.join(PROJECTS_ROOT, name)) }.sort
  end

  # プロジェクト名をパストラバーサル対策しつつ絶対パスに変換する。
  # 未指定時は available_projects の先頭を既定として使う
  # (project を指定しない古いクライアントとの互換性のため)。
  # 戻り値は [プロジェクト名, 絶対パス] のペア。
  def project_root(name)
    name = name.to_s.empty? ? nil : name.to_s
    name ||= available_projects.first
    raise ArgumentError, "no project available" if name.nil?
    raise ArgumentError, "invalid project" if name.include?(File::SEPARATOR) || name.include?("..")

    full = File.expand_path(File.join(PROJECTS_ROOT, name))
    root_with_sep = PROJECTS_ROOT + File::SEPARATOR
    raise ArgumentError, "invalid project" unless full.start_with?(root_with_sep) && File.directory?(full)

    [name, full]
  end

  # path traversal (../ などによる範囲外アクセス) を防ぎつつ絶対パスに変換する
  def safe_path(root, rel_path)
    full = File.expand_path(File.join(root, rel_path.to_s))
    root_with_sep = root + File::SEPARATOR
    unless full == root || full.start_with?(root_with_sep)
      raise ArgumentError, "invalid path"
    end
    full
  end

  def json_error(status, message)
    halt status, { error: message }.to_json
  end
end

# エディタ画面(Funicular / PicoRuby.wasm 版)
get "/" do
  send_file File.join(FUNICULAR_ROOT, "index.html")
end

# Funicular アプリの Ruby ソース。
# <script type="text/ruby" src="/ruby/..."> から読み込まれる。
get %r{/ruby/(.+\.rb)} do |rel|
  full = File.expand_path(File.join(FUNICULAR_ROOT, "ruby", rel))
  root_with_sep = File.join(FUNICULAR_ROOT, "ruby") + File::SEPARATOR

  json_error(400, "invalid path") unless full.start_with?(root_with_sep)
  halt 404 unless File.file?(full)

  content_type "text/plain", charset: "utf-8"
  File.read(full)
end

# 旧エディタ画面(textarea + Prism を素の JavaScript で書いた版)。
# Funicular 版と挙動を比較したいとき用に残してある。
get "/legacy" do
  erb :index
end

# 編集可能なプロジェクト一覧を返す
get "/api/projects" do
  content_type :json
  available_projects.to_json
end

# 指定プロジェクトの編集可能なファイル一覧を返す
get "/api/files" do
  content_type :json

  begin
    _name, root = project_root(params[:project])
  rescue ArgumentError
    json_error(400, "invalid project")
  end

  files = Dir.glob(File.join(root, "**", "*")).select do |f|
    File.file?(f) && ALLOWED_EXTENSIONS.include?(File.extname(f))
  end

  relative_paths = files.map { |f| f.sub(root + File::SEPARATOR, "") }.sort

  relative_paths.to_json
end

# 指定ファイルの内容を返す
get "/api/file" do
  content_type :json

  rel = params[:path]
  json_error(400, "path is required") if rel.nil? || rel.empty?

  begin
    _name, root = project_root(params[:project])
    full = safe_path(root, rel)
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
    _name, root = project_root(payload["project"])
    full = safe_path(root, rel)
  rescue ArgumentError
    json_error(400, "invalid path")
  end

  # 既存ファイルの上書きのみ許可(新規ファイル作成はサンプルでは対象外)
  json_error(404, "file not found") unless File.file?(full)
  json_error(400, "unsupported file type") unless ALLOWED_EXTENSIONS.include?(File.extname(full))

  File.write(full, content)

  { status: "ok", path: rel, bytes: content.bytesize }.to_json
end
