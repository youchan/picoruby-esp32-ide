require "sinatra"
require "json"
require "open3"
require "shellwords"

set :public_folder, File.join(__dir__, "public")
set :views, File.join(__dir__, "views")

# 開発中(bin/dev、RACK_ENV=development)は app/ をbind mountして頻繁にファイルを
# 差し替えるため、ブラウザキャッシュのせいで更新が反映されずハマる方が実害が大きい。
# 本番相当(Dockerfileの素のCMD起動、RACK_ENV=production)では逆にキャッシュさせたい。
if settings.development?
  set :static_cache_control, [:no_store, :no_cache, :must_revalidate]

  before do
    cache_control :no_store, :no_cache, :must_revalidate
  end
else
  set :static_cache_control, [:public, max_age: 3600]

  before do
    cache_control :public, max_age: 3600
  end
end

# 編集対象として公開するプロジェクト群のルートディレクトリ。
# 直下の各ディレクトリ(例: projects/sample)がそれぞれ独立した編集対象になる。
PROJECTS_ROOT = File.expand_path("../projects", __dir__)

# Funicular(PicoRuby.wasm)版フロントエンドの置き場所
FUNICULAR_ROOT = File.expand_path("funicular", __dir__)

# ビルド対象の R2P2-ESP32 プロジェクトルート。
# Dockerfile では /R2P2-ESP32 に、ローカル開発では ../R2P2-ESP32 に配置される
# (projects/ と同じ __dir__ 相対の解決方法に合わせてある)。
R2P2_ESP32_ROOT = File.expand_path("../R2P2-ESP32", __dir__)

# 編集を許可する拡張子(Ruby / C)
ALLOWED_EXTENSIONS = %w[.rb .c .h].freeze

# setup_esp32xxx タスクが存在するターゲット一覧(R2P2-ESP32/rakelib/setup.rake参照)。
# rakeタスク名の組み立てに使うため、ここに無い値は拒否する(コマンドインジェクション対策)。
PLATFORM_TARGETS = %w[esp32 esp32c3 esp32c6 esp32h2 esp32p4 esp32s3].freeze

# サーバ内で1本しか同時実行しないバックグラウンドジョブの実行状態を管理する。
# ビルド(idf.py build)とプラットフォームセットアップ(rake setup_xxx)の両方で使う、
# 複数人が同時に叩く運用は想定していない簡易な共有ステート。
class BackgroundJob
  # ブラウザ(PicoRuby.wasm)側でのJSONパース/描画が重くなりすぎないよう、
  # API経由で返すログは末尾のみに切り詰める。全量は @state[:log] に残る。
  LOG_TAIL_LIMIT = 8_000

  def initialize
    @mutex = Mutex.new
    @state = { status: "idle", log: "", started_at: nil, finished_at: nil }
  end

  # 実行中でなければバックグラウンドスレッドでcmdを開始してtrueを返す。
  # 実行中ならなにもせずfalseを返す(呼び出し側で409にする)。
  def start(cmd)
    started = @mutex.synchronize do
      break false if @state[:status] == "running"

      @state[:status] = "running"
      @state[:log] = ""
      @state[:started_at] = Time.now.to_i
      @state[:finished_at] = nil
      true
    end

    Thread.new { run(cmd) } if started
    started
  end

  def to_response_json
    @mutex.synchronize do
      full_log = @state[:log]
      truncated = full_log.length > LOG_TAIL_LIMIT

      {
        status: @state[:status],
        log: truncated ? full_log[-LOG_TAIL_LIMIT..-1] : full_log,
        log_truncated: truncated,
        started_at: @state[:started_at],
        finished_at: @state[:finished_at]
      }.to_json
    end
  end

  private

  def run(cmd)
    Open3.popen2e("bash", "-c", cmd) do |stdin, stdout_and_stderr, wait_thread|
      stdin.close
      stdout_and_stderr.each_line do |line|
        @mutex.synchronize { @state[:log] << line }
      end

      success = wait_thread.value.success?
      @mutex.synchronize do
        @state[:status] = success ? "success" : "failed"
        @state[:finished_at] = Time.now.to_i
      end
    end
  rescue StandardError => e
    @mutex.synchronize do
      @state[:status] = "failed"
      @state[:log] << "\n[#{e.class}] #{e.message}\n"
      @state[:finished_at] = Time.now.to_i
    end
  end
end

BUILD_JOB = BackgroundJob.new
PLATFORM_JOB = BackgroundJob.new

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
# send_file だと Last-Modified を自動付与し、ブラウザが If-Modified-Since で
# 再検証してキャッシュ済みの古い本文を使い続けることがあった(development環境で
# no-store を指定していても発生した)ため、File.read で素朴に返す。
get "/" do
  content_type :html
  File.read(File.join(FUNICULAR_ROOT, "index.html"))
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

# idf.py / rake は ESP-IDF の export.sh を読み込んだシェルでしか使えない。
# コンテナのエントリポイントで export 済みの環境ならそのまま動くが、
# (docker exec 経由など)export されていない場合に備えて明示的に読み込む。
def r2p2_shell_command(inner_cmd)
  "cd #{Shellwords.escape(R2P2_ESP32_ROOT)} && " \
    "if [ -n \"$IDF_PATH\" ] && [ -f \"$IDF_PATH/export.sh\" ]; then " \
    ". \"$IDF_PATH/export.sh\" > /dev/null; fi && #{inner_cmd}"
end

# R2P2-ESP32 のビルド状態(実行中/成功/失敗/未実行)とログを返す。
# UI 側はこれをポーリングして進捗を表示する。
get "/api/build" do
  content_type :json
  BUILD_JOB.to_response_json
end

# idf.py build -DPICORB_VM=xxx に渡すフラグ(R2P2-ESP32/Rakefile の PICORB_VMS と同じ対応)。
BUILD_VM_FLAGS = { "femtoruby" => "mrubyc", "picoruby" => "mruby" }.freeze

# 外部USB-UART変換チップを持たないボード向けの設定フラグメント
# (R2P2-ESP32/sdkconfigs/usb_console、README.md「Hardware-specific Configuration」参照)。
USB_CONSOLE_SDKCONFIG_DEFAULTS = "sdkconfig.defaults;sdkconfigs/usb_console"

# 現在の sdkconfig が USB Console設定でビルドされているかどうか。
# sdkconfigが無い(セットアップ直後、または一度もビルドしていない)場合はfalse扱い。
def sdkconfig_has_usb_console?
  sdkconfig_path = File.join(R2P2_ESP32_ROOT, "sdkconfig")
  return false unless File.file?(sdkconfig_path)

  File.foreach(sdkconfig_path).any? { |line| line.start_with?("CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG=y") }
end

# R2P2-ESP32 のビルド(idf.py build)をバックグラウンドで開始する。
# 実行中に重ねて叩かれた場合は 409 を返す(同時に複数走らせない)。
#
# body(JSON、両方省略可):
#   vm: "femtoruby" | "picoruby" — 省略時は現在のCMake設定のデフォルトVMのまま
#   usb_console: true | false    — 省略時は現在のsdkconfigの設定のまま
post "/api/build" do
  content_type :json

  payload =
    begin
      body = request.body.read
      body.empty? ? {} : JSON.parse(body)
    rescue JSON::ParserError
      json_error(400, "invalid json body")
    end

  vm = payload["vm"].to_s.empty? ? nil : payload["vm"]
  json_error(400, "invalid vm") if vm && !BUILD_VM_FLAGS.key?(vm)
  usb_console = payload["usb_console"] == true

  build_cmd = +"idf.py build"
  build_cmd << " -DPICORB_VM=#{BUILD_VM_FLAGS[vm]}" if vm

  full_cmd =
    if usb_console != sdkconfig_has_usb_console?
      # SDKCONFIG_DEFAULTS は sdkconfig ファイルが無いときにしか読まれない仕組みなので、
      # 現在の設定と要求された設定が食い違うときだけ sdkconfig を消してビルドし直す
      # (README.md「If you change SDKCONFIG_DEFAULTS, delete the sdkconfig file and
      # rebuild from scratch」参照。fullclean/deep_cleanでも消えないので明示的に消す)。
      # 値が変わらない限りはこのクリーンビルドを避け、従来通りの差分ビルドのままにする。
      sdkconfig_defaults = usb_console ? USB_CONSOLE_SDKCONFIG_DEFAULTS : "sdkconfig.defaults"
      "rm -f sdkconfig && SDKCONFIG_DEFAULTS=#{Shellwords.escape(sdkconfig_defaults)} #{build_cmd}"
    else
      build_cmd
    end

  started = BUILD_JOB.start(r2p2_shell_command(full_cmd))
  json_error(409, "build already running") unless started

  { status: "ok" }.to_json
end

# プラットフォーム(ターゲットチップ)セットアップの実行状態とログを返す。
get "/api/platform" do
  content_type :json
  PLATFORM_JOB.to_response_json
end

# 指定プラットフォーム向けに `rake setup_#{platform}` をバックグラウンドで実行する。
# setup_esp32xxx は deep_clean + setup(mrubyの再ビルド) + idf.py set-target という
# 重い処理の直列実行(R2P2-ESP32/rakelib/setup.rake参照)。
post "/api/platform" do
  content_type :json

  payload =
    begin
      JSON.parse(request.body.read)
    rescue JSON::ParserError
      json_error(400, "invalid json body")
    end

  platform = payload["platform"]
  json_error(400, "invalid platform") unless PLATFORM_TARGETS.include?(platform)

  started = PLATFORM_JOB.start(r2p2_shell_command("rake setup_#{platform}"))
  json_error(409, "platform setup already running") unless started

  { status: "ok", platform: platform }.to_json
end

# デバイスへの書き込み(インストール)は ESP Web Tools
# (https://esphome.github.io/esp-web-tools/、index.html でCDN読み込み)経由の
# ブラウザのWeb Serial APIで行う。サーバはビルド成果物からマニフェストと.binを
# 配信するだけで、実際の書き込み処理はブラウザ側(esp-web-install-button)が担う。
FIRMWARE_BUILD_DIR = File.join(R2P2_ESP32_ROOT, "build")

# idf.py set-target のターゲット名 → ESP Web Tools の chipFamily 名。
# ESP Web Tools が対応しているチップ一覧(esp-web-tools/src/const.ts の Build#chipFamily)
# のうち、R2P2-ESP32側がサポートしている(PLATFORM_TARGETSにある)ものだけ載せてある。
CHIP_FAMILY_MAP = {
  "esp32" => "ESP32",
  "esp32c3" => "ESP32-C3",
  "esp32c6" => "ESP32-C6",
  "esp32h2" => "ESP32-H2",
  "esp32p4" => "ESP32-P4",
  "esp32s3" => "ESP32-S3"
}.freeze

# ESP Web Tools 用のマニフェストを、直近のビルド成果物
# (build/project_description.json の "target" と build/flash_args)から動的に組み立てる。
# flash_args は `idf.py build` が生成する、esptool write_flash にそのまま渡せる
# "<オフセット(16進)> <binへの相対パス>" の行の並び(1行目は --flash_mode 等のオプション行)。
get "/api/firmware/manifest.json" do
  content_type :json

  desc_path = File.join(FIRMWARE_BUILD_DIR, "project_description.json")
  flash_args_path = File.join(FIRMWARE_BUILD_DIR, "flash_args")
  json_error(404, "not built yet") unless File.file?(desc_path) && File.file?(flash_args_path)

  target = JSON.parse(File.read(desc_path))["target"]
  chip_family = CHIP_FAMILY_MAP[target]
  json_error(500, "unsupported target: #{target}") unless chip_family

  parts = File.readlines(flash_args_path).drop(1).filter_map do |line|
    line = line.strip
    next if line.empty?

    offset_hex, rel_path = line.split(" ", 2)
    # rel_path は "bootloader/bootloader.bin" のようにサブディレクトリを含むことがある。
    # basename に切り詰めると実体(build/bootloader/bootloader.bin)と食い違って
    # 404になるため、相対パスのままURLに使う(下の配信ルート側もそれに合わせてある)。
    { path: "/api/firmware/#{rel_path}", offset: Integer(offset_hex, 16) }
  end

  {
    name: "R2P2-ESP32",
    version: Time.now.strftime("%Y%m%d%H%M%S"),
    builds: [{ chipFamily: chip_family, parts: parts }]
  }.to_json
end

# ビルド成果物の .bin ファイルを配信する。flash_args の相対パスをそのまま受け取る
# (例: "bootloader/bootloader.bin" のようにサブディレクトリを含むことがある)ので、
# 固定セグメントの :filename ではなくワイルドカードで受ける。
# manifestのpartsが返すpathはここに合わせてある。
get "/api/firmware/*" do
  rel_path = params[:splat].first
  json_error(400, "invalid filename") unless rel_path.end_with?(".bin")

  full =
    begin
      safe_path(FIRMWARE_BUILD_DIR, rel_path)
    rescue ArgumentError
      json_error(400, "invalid path")
    end

  json_error(404, "file not found") unless File.file?(full)

  content_type "application/octet-stream"
  File.read(full, mode: "rb")
end
