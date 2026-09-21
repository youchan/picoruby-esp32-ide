require "sinatra"
require "json"
require "open3"
require "shellwords"
require "fileutils"
require "yaml"
require_relative "background_job"

set :public_folder, File.join(__dir__, "public")
set :views, File.join(__dir__, "views")

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

PROJECTS_ROOT = File.expand_path("../projects", __dir__)
FUNICULAR_ROOT = File.expand_path("funicular", __dir__)
R2P2_ESP32_ROOT = File.expand_path("../R2P2-ESP32", __dir__)

ALLOWED_EXTENSIONS = %w[.rb .c .h .rake].freeze
PLATFORM_TARGETS = %w[esp32 esp32c3 esp32c6 esp32h2 esp32p4 esp32s3].freeze

# 1プロジェクト = projects/<name>/ の中に app/・mrbgems/・build_config.rb を
# まとめて持つディレクトリ、という単位にしてある(app/mrbgemsをprojects直下に
# 並べて種別を自動判定する方式から変更。1つのアプリと、それが使う自作mrbgem群を
# 1プロジェクトとして丸ごと持ち歩けるように)。
APP_DIRNAME = "app"
MRBGEMS_DIRNAME = "mrbgems"

# プロジェクト固有のビルド設定。ユーザーが直接編集できる普通のファイルという位置づけ
# (以前はGemsダイアログが生成する専用ファイルだったが、mrbgemがプロジェクトの中に
# 物理的に入るようになったことで、追加するmrbgemを選ぶUIは不要になった)。
BUILD_CONFIG_FILENAME = "build_config.rb"

# ビルド時にPROJECT_BUILD_CONFIG経由でR2P2-ESP32へ実際に渡すファイル。
# mrbgems/以下から自動生成した`conf.gem gemdir:`の並びの後ろに、プロジェクトの
# build_config.rbの内容をそのまま連結したもの(ユーザーが書いたbuild_config.rb自体は
# 書き換えない)。
GENERATED_BUILD_CONFIG_FILENAME = ".build_config.generated.rb"

# appプロジェクトのapp/以下を起動スクリプトとして実機で動かすための仕組み。
# R2P2-ESP32はmain/CMakeLists.txtの`littlefs_create_partition_image`でR2P2-ESP32/storage/
# 以下をそのままstorageパーティション(littlefs)のイメージにし、起動スクリプト
# (components/picoruby-esp32/mrblib/main_task.rb)が起動のたびに
# `/home/app.rb`(=storage/home/app.rb)を自動でloadする、というR2P2本来の仕組みが
# 既にある。そのため main_task.rb 側の改造は不要で、ビルド直前にprojectのapp/以下を
# storage/home/へまるごとコピーするだけでよい。
STORAGE_HOME_DIR = File.join(R2P2_ESP32_ROOT, "storage", "home")

BUILD_JOB = BackgroundJob.new
PLATFORM_JOB = BackgroundJob.new

helpers do
  def available_projects
    Dir.children(PROJECTS_ROOT).select { |name| File.directory?(File.join(PROJECTS_ROOT, name)) }.sort
  end

  # プロジェクト名をパストラバーサル対策しつつ絶対パスに変換する。
  # 戻り値は [プロジェクト名, 絶対パス] のペア。
  def project_root(name)
    raise ArgumentError, "invalid project" if name.include?(File::SEPARATOR) || name.include?("..")

    full = File.expand_path(File.join(PROJECTS_ROOT, name))
    root_with_sep = PROJECTS_ROOT + File::SEPARATOR
    raise ArgumentError, "invalid project" unless full.start_with?(root_with_sep) && File.directory?(full)

    full
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

get "/" do
  erb :index
end

# Funicular アプリの Ruby ソース。
get %r{/ruby/(.+\.rb)} do |rel|
  full = File.expand_path(File.join(FUNICULAR_ROOT, "ruby", rel))
  root_with_sep = File.join(FUNICULAR_ROOT, "ruby") + File::SEPARATOR

  json_error(400, "invalid path") unless full.start_with?(root_with_sep)
  halt 404 unless File.file?(full)

  content_type "text/plain", charset: "utf-8"
  File.read(full)
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
    root = project_root(params[:project])
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
    root = project_root(params[:project])
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
    root = project_root(payload["project"])
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

# --- プロジェクト設定(ターゲット・VM・USB Console) ----------------------
#
# 以前はビルドボタンを押すたびにダイアログでVM/USB Consoleを選ばせ、ターゲット
# チップはメニューバーの常設セレクトで選ぶ形だったが、「プロジェクトの設定として
# プロジェクトに含めたい」というフィードバックを受けて、プロジェクトごとに
# 隠しファイル`.config.yml`(PROJECT_CONFIG_FILENAME)へ永続化する方式に変更した。
# UI側は「設定」ダイアログで編集し、ビルド/プラットフォームセットアップは
# その時点の設定値をそのまま使って即座に実行するだけになる。

PROJECT_CONFIG_FILENAME = ".config.yml"

# ファイルが無い、あるいは壊れている場合は「何も設定されていない」扱い
# (platform/vmはnil = 未選択・デフォルト、usb_consoleはfalse)にする。
def read_project_config(root)
  path = File.join(root, PROJECT_CONFIG_FILENAME)
  data =
    begin
      File.file?(path) ? YAML.safe_load(File.read(path)) : nil
    rescue Psych::SyntaxError
      nil
    end
  data ||= {}

  {
    "platform" => data["platform"],
    "vm" => data["vm"],
    "usb_console" => data["usb_console"] == true
  }
end

get "/api/projects/:name/config" do
  content_type :json

  root =
    begin
      project_root(params[:name])
    rescue ArgumentError
      json_error(400, "invalid project")
    end

  read_project_config(root).to_json
end

# body(JSON): { platform:, vm:, usb_console: } — platform/vmはnull(未選択)も許可
post "/api/projects/:name/config" do
  content_type :json

  root =
    begin
      project_root(params[:name])
    rescue ArgumentError
      json_error(400, "invalid project")
    end

  payload =
    begin
      JSON.parse(request.body.read)
    rescue JSON::ParserError
      json_error(400, "invalid json body")
    end

  platform = payload["platform"]
  json_error(400, "invalid platform") if platform && !PLATFORM_TARGETS.include?(platform)

  vm = payload["vm"]
  json_error(400, "invalid vm") if vm && !BUILD_VM_FLAGS.key?(vm)

  config = { "platform" => platform, "vm" => vm, "usb_console" => payload["usb_console"] == true }
  File.write(File.join(root, PROJECT_CONFIG_FILENAME), YAML.dump(config))

  { status: "ok" }.to_json
end

# --- mrbgemのビルド組み込み -------------------------------------------
#
# R2P2-ESP32本体のbuild_config(components/picoruby-esp32/build_config/*.rb)は
# xtensa/riscv・femtoruby/picoruby の組み合わせで4種あり、ツールチェイン設定など
# 込み入った内容を持つ。これをプロジェクトごとに複製すると本家の変更に追従できなく
# なるため、複製はせず「本家の設定を評価した最後に、プロジェクト側の追加/除外だけを
# 差し込む」フックをDockerfileで1行だけ本家4ファイルに追加している(該当箇所は
# `conf.instance_eval(File.read(ENV['PROJECT_BUILD_CONFIG'])) if ...`)。
#
# projects/<project>/mrbgems/以下にあるものは全部自動でビルドに含める(選ぶUIは無い)。
# プロジェクトの中に物理的にmrbgemを置く=そのプロジェクトで使う、という構造そのものが
# 選択を兼ねているので、ビルドのたびに`generated_build_config_content`で
# 「その時点でmrbgems/以下にあるgem一覧」から`conf.gem gemdir:`の並びを作り、
# その後ろにプロジェクトのbuild_config.rb(デフォルトgemを外したい場合はここに
# `conf.gems.reject!`を書く、普通の編集可能ファイル)をそのまま連結したものを
# PROJECT_BUILD_CONFIG経由で渡す。gemdir(自作mrbgemの絶対パス)は常にコンテナ内の
# 絶対パスで書く(相対パス解決の基点があいまいなmruby側の挙動に依存しないため)。

def project_mrbgem_paths(root)
  mrbgems_dir = File.join(root, MRBGEMS_DIRNAME)
  return [] unless Dir.exist?(mrbgems_dir)

  Dir.children(mrbgems_dir).select { |name| File.directory?(File.join(mrbgems_dir, name)) }.sort
    .map { |name| File.join(mrbgems_dir, name) }
end

def generated_build_config_content(root)
  lines = ["# picoruby-esp32-ide が自動生成する部分(#{MRBGEMS_DIRNAME}/以下のgemを追加する)"]
  project_mrbgem_paths(root).each { |path| lines << "conf.gem gemdir: #{path.inspect}" }

  build_config_path = File.join(root, BUILD_CONFIG_FILENAME)
  if File.file?(build_config_path)
    lines << ""
    lines << "# ここから下は #{BUILD_CONFIG_FILENAME} の内容"
    lines << File.read(build_config_path)
  end

  lines.join("\n") + "\n"
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
# VM・USB Consoleはリクエストでは受け取らず、そのプロジェクトの`.config.yml`
# (read_project_config)に保存されている値をそのまま使う。
#
# body(JSON):
#   project: "hello_world_project" のようなプロジェクト名(必須)。app/以下を
#            実機の起動スクリプトに、mrbgems/以下とbuild_config.rbをビルド設定に
#            それぞれ反映させる(詳細は上のコメント参照)
post "/api/build" do
  content_type :json

  payload =
    begin
      body = request.body.read
      body.empty? ? {} : JSON.parse(body)
    rescue JSON::ParserError
      json_error(400, "invalid json body")
    end

  project_name = payload["project"]
  json_error(400, "project is required") if project_name.to_s.empty?

  root =
    begin
      project_root(project_name)
    rescue ArgumentError
      json_error(400, "invalid project")
    end

  # そのprojectのapp/以下を実機の起動スクリプトにする(STORAGE_HOME_DIR参照)。
  # 前回別プロジェクトをビルドしたときの残骸が残らないよう、まずstorage/home/を
  # 空にしてからコピーし直す。
  FileUtils.mkdir_p(STORAGE_HOME_DIR)
  FileUtils.rm_rf(Dir.glob(File.join(STORAGE_HOME_DIR, "*")))
  project_app_dir = File.join(root, APP_DIRNAME)
  if Dir.exist?(project_app_dir)
    FileUtils.cp_r(Dir.glob(File.join(project_app_dir, "*")), STORAGE_HOME_DIR)
  end

  project_config = read_project_config(root)
  vm = project_config["vm"]
  usb_console = project_config["usb_console"]

  build_cmd = +"idf.py build"
  build_cmd << " -DPICORB_VM=#{BUILD_VM_FLAGS[vm]}" if vm

  # projects/<project>/mrbgems/以下の現在の一覧とbuild_config.rbから、実際に
  # R2P2-ESP32へ渡すファイルをビルドのたびに作り直す(generated_build_config_content参照)。
  generated_build_config = File.join(root, GENERATED_BUILD_CONFIG_FILENAME)
  File.write(generated_build_config, generated_build_config_content(root))
  env_assignments = ["PROJECT_BUILD_CONFIG=#{Shellwords.escape(generated_build_config)}"]

  if usb_console != sdkconfig_has_usb_console?
    # SDKCONFIG_DEFAULTS は sdkconfig ファイルが無いときにしか読まれない仕組みなので、
    # 現在の設定と要求された設定が食い違うときだけ sdkconfig を消してビルドし直す
    # (README.md「If you change SDKCONFIG_DEFAULTS, delete the sdkconfig file and
    # rebuild from scratch」参照。fullclean/deep_cleanでも消えないので明示的に消す)。
    # 値が変わらない限りはこのクリーンビルドを避け、従来通りの差分ビルドのままにする。
    sdkconfig_defaults = usb_console ? USB_CONSOLE_SDKCONFIG_DEFAULTS : "sdkconfig.defaults"
    env_assignments << "SDKCONFIG_DEFAULTS=#{Shellwords.escape(sdkconfig_defaults)}"
    full_cmd = "rm -f sdkconfig && #{env_assignments.join(' ')} #{build_cmd}"
  else
    full_cmd = env_assignments.empty? ? build_cmd : "#{env_assignments.join(' ')} #{build_cmd}"
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

# 指定プロジェクトの`.config.yml`に設定されているターゲットへ向けて
# `rake setup_#{platform}` をバックグラウンドで実行する。ターゲット自体は
# リクエストでは受け取らず、プロジェクト設定ダイアログで保存された値を使う。
# setup_esp32xxx は deep_clean + setup(mrubyの再ビルド) + idf.py set-target という
# 重い処理の直列実行(R2P2-ESP32/rakelib/setup.rake参照)。
#
# body(JSON): { project: "hello_world_project" }(必須)
post "/api/platform" do
  content_type :json

  payload =
    begin
      JSON.parse(request.body.read)
    rescue JSON::ParserError
      json_error(400, "invalid json body")
    end

  project_name = payload["project"]
  json_error(400, "project is required") if project_name.to_s.empty?

  root =
    begin
      project_root(project_name)
    rescue ArgumentError
      json_error(400, "invalid project")
    end

  platform = read_project_config(root)["platform"]
  json_error(400, "platform is not configured for this project") if platform.to_s.empty?

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
