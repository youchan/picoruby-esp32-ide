# 最上部のメニュー/グローバルステータスバー。
#
# プロジェクトの切り替えは左のファイルツリー(ProjectList)側で行うが、
# 「ビルド開始」「プラットフォーム選択」「デバイスにインストール」は
# 実行頻度が高く画面のどこにいても操作したい機能なので、ここに集約している。
# 他のパネルと同じく表示専用で、実処理(状態管理・API呼び出し)は
# props[:on_build] / props[:on_platform_select] 経由で親(EditorApp)に委譲する。
class MenuBar < Funicular::Component
  MANIFEST_PATH = '/api/firmware/manifest.json'

  STATUS_LABELS = {
    'idle' => 'ビルド未実行',
    'running' => 'ビルド中…',
    'success' => 'ビルド成功',
    'failed' => 'ビルド失敗'
  }.freeze

  def render
    div(class: 'menu-bar') do
      span(class: 'menu-bar-title') { 'PicoRuby ESP32 IDE' }
      render_project_chip
      render_platform_select
      div(class: 'menu-bar-spacer')
      render_build_button
      render_status_pill
      render_install_button
    end
  end

  def handle_build(event)
    event.preventDefault
    on_build = props[:on_build]
    on_build.call if on_build
  end

  # <select> の変更イベント。プレースホルダ("ターゲット未選択")が選ばれた場合は無視する。
  def handle_platform_change(event)
    node = refs[:platform_select]
    return unless node

    value = node[:value].to_s
    return if value.empty?

    on_platform_select = props[:on_platform_select]
    on_platform_select.call(value) if on_platform_select
  end

  private

  def render_project_chip
    span(class: 'menu-bar-chip project') { props[:current_project] || 'プロジェクト未選択' }
  end

  # プラットフォーム選択(旧 PlatformPanel のボタン群をここに集約したもの)。
  # disabled は「属性を付けない/付ける」で切り替える
  # (build_panel.rb の render_vm_select と同じ理由: false を渡す書き方に依存しないため)。
  def render_platform_select
    if props[:platform_building]
      tag(:select, ref: :platform_select, onchange: :handle_platform_change, disabled: true) { render_platform_options }
    else
      tag(:select, ref: :platform_select, onchange: :handle_platform_change) { render_platform_options }
    end
  end

  def render_platform_options
    if props[:selected_platform].nil?
      tag(:option, value: '', selected: true, disabled: true) { 'ターゲット未選択' }
    else
      tag(:option, value: '', disabled: true) { 'ターゲット未選択' }
    end

    PlatformPanel::PLATFORMS.each do |name|
      if name == props[:selected_platform]
        tag(:option, value: name, selected: true) { name }
      else
        tag(:option, value: name) { name }
      end
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
  def render_install_button
    tag(:'esp-web-install-button', manifest: MANIFEST_PATH) do
      button(slot: 'activate', class: 'menu-install') { 'デバイスにインストール' }
      span(slot: 'unsupported', class: 'menu-bar-hint') { '未対応ブラウザ' }
      span(slot: 'not-allowed', class: 'menu-bar-hint') { 'HTTPS必須' }
    end
  end

  def status_label
    STATUS_LABELS[props[:build_status]] || props[:build_status].to_s
  end
end
