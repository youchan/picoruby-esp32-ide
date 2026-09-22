# 最上部のメニュー/グローバルステータスバー。
#
# プロジェクトの切り替えもここのドロップダウンで行う(以前はサイドバーのProjectList
# だったが、「上部のドロップダウンから選べるようにしたい」という要望で移動した)。
# ターゲットチップ・VM・USB Consoleは以前ここに常設セレクト/ビルド時ダイアログで
# 出していたが、「プロジェクトの設定としてプロジェクトに含めたい」という
# フィードバックを受けてプロジェクトごとの`.config.yml`に持たせる方式に変更した。
# そのため、ここには設定値を編集する「設定」ボタンと、その設定値をそのまま使って
# 実行するだけの「セットアップ」「ビルド開始」ボタンだけが残っている。
# 他のパネルと同じく表示専用で、実処理(状態管理・API呼び出し)は
# props[:on_project_select] / props[:on_settings] / props[:on_setup] /
# props[:on_build] 経由で親(EditorApp)に委譲する。
class MenuBar < Funicular::Component
  STATUS_LABELS = {
    'idle' => 'ビルド未実行',
    'running' => 'ビルド中…',
    'success' => 'ビルド成功',
    'failed' => 'ビルド失敗'
  }.freeze

  def render
    div(class: 'menu-bar') do
      span(class: 'menu-bar-title') { 'PicoRuby ESP32 IDE' }
      render_project_select
      div(class: 'menu-bar-spacer')
      render_settings_button
      render_setup_button
      render_build_button
      render_status_pill
      render_install_button
    end
  end

  # <select> の変更イベント。プレースホルダ("プロジェクト未選択")が選ばれた場合は無視する。
  def handle_project_change(event)
    node = refs[:project_select]
    return unless node

    value = node[:value].to_s
    return if value.empty?

    on_project_select = props[:on_project_select]
    on_project_select.call(value) if on_project_select
  end

  def handle_settings(event)
    event.preventDefault
    on_settings = props[:on_settings]
    on_settings.call if on_settings
  end

  def handle_setup(event)
    event.preventDefault
    on_setup = props[:on_setup]
    on_setup.call if on_setup
  end

  def handle_build(event)
    event.preventDefault
    on_build = props[:on_build]
    on_build.call if on_build
  end

  private

  def render_project_select
    projects = props[:projects] || []

    if props[:loading_projects] || projects.empty?
      tag(:select, disabled: true) { tag(:option, value: '') { 'プロジェクト未選択' } }
    else
      tag(:select, ref: :project_select, onchange: :handle_project_change) { render_project_options(projects) }
    end
  end

  def render_project_options(projects)
    projects.each do |name|
      if name == props[:current_project]
        tag(:option, value: name, selected: true) { name }
      else
        tag(:option, value: name) { name }
      end
    end
  end

  def render_settings_button
    button(class: 'menu-settings', onclick: :handle_settings) { '設定' }
  end

  # ターゲットが未設定なら押せない(設定ダイアログで選んでもらう)。
  def render_setup_button
    platform = value_of(props[:project_config], 'platform')

    if props[:platform_building]
      button(class: 'menu-setup', disabled: true) { 'セットアップ中…' }
    elsif platform.to_s.empty?
      button(class: 'menu-setup', disabled: true) { 'ターゲット未設定' }
    else
      button(class: 'menu-setup', onclick: :handle_setup) { "#{platform}をセットアップ" }
    end
  end

  def render_build_button
    if props[:building]
      button(class: 'menu-build', disabled: true) { 'ビルド中…' }
    else
      button(class: 'menu-build', onclick: :handle_build) { 'ビルド開始' }
    end
  end

  def render_status_pill
    span(class: "menu-bar-status #{props[:build_status]}") { status_label }
  end

  # 実際の書き込み処理はブラウザのWeb Serial API経由でESP Web Tools
  # (esp-web-install-button カスタム要素)が行う。旧 install_panel.rb と同じ使い方。
  # ビルド成果物がプロジェクトごとに分かれた(r2p2_state_dir参照)ので、
  # マニフェストURLにも現在のプロジェクトをクエリパラメータとして含める。
  def render_install_button
    current_project = props[:current_project]
    if current_project.to_s.empty?
      button(class: 'menu-install', disabled: true) { 'デバイスにインストール' }
    else
      manifest_path = "/api/firmware/manifest.json?project=#{encode(current_project)}"
      tag(:'esp-web-install-button', manifest: manifest_path) do
        button(slot: 'activate', class: 'menu-install') { 'デバイスにインストール' }
        span(slot: 'unsupported', class: 'menu-bar-hint') { '未対応ブラウザ' }
        span(slot: 'not-allowed', class: 'menu-bar-hint') { 'HTTPS必須' }
      end
    end
  end

  def status_label
    STATUS_LABELS[props[:build_status]] || props[:build_status].to_s
  end

  def value_of(data, key)
    return nil unless data
    data[key] || data[key.to_sym]
  end

  def encode(str)
    JS.global.encodeURIComponent(str).to_s
  end
end
