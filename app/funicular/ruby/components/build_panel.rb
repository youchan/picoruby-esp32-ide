# R2P2-ESP32のビルド操作パネル(ビルド開始ボタン・状態表示・ログ表示)。
#
# 他のコンポーネントと同じく表示専用。ビルドの開始/ログ更新は
# props[:on_build] / props[:on_refresh] 経由で親(EditorApp)に委譲する。
#
# ビルドはサーバ側でバックグラウンド実行されるため、進捗はポーリングでしか
# 追えない。ビルド中は親(EditorApp)が JS.global.setTimeout 経由で自動的に
# ログを取りに行くので、ここでは表示に徹する。「ログを更新」ボタンは
# ポーリング前に最新状態をすぐ見たいときの手動トリガーとして残してある。
class BuildPanel < Funicular::Component
  STATUS_LABELS = {
    'idle' => 'ビルド未実行',
    'running' => 'ビルド中…',
    'success' => 'ビルド成功',
    'failed' => 'ビルド失敗'
  }

  # 空文字は「現在のCMake設定のデフォルトVMのまま」(idf.py buildにVM未指定)を意味する。
  VM_OPTIONS = [
    ['', 'デフォルト'],
    ['femtoruby', 'FemtoRuby (mruby/c)'],
    ['picoruby', 'PicoRuby (mruby)']
  ].freeze

  def render
    div(class: 'build-panel') do
      div(class: 'build-panel-header') do
        h1 { 'R2P2-ESP32 Build' }
        render_refresh_button
        span(class: "build-status #{props[:build_status]}") { status_label }
      end
      div(class: 'build-options') do
        render_vm_select
        render_usb_console_checkbox
      end
      tag(:pre, class: 'build-log') { build_log_text }
    end
  end

  def handle_refresh(event)
    event.preventDefault
    on_refresh = props[:on_refresh]
    on_refresh.call if on_refresh
  end

  def handle_vm_change(event)
    node = refs[:vm_select]
    return unless node
    on_vm_change = props[:on_vm_change]
    on_vm_change.call(node[:value].to_s) if on_vm_change
  end

  def handle_usb_console_change(event)
    node = refs[:usb_console_checkbox]
    return unless node
    on_usb_console_change = props[:on_usb_console_change]
    on_usb_console_change.call(truthy?(node[:checked])) if on_usb_console_change
  end

  private

  def render_refresh_button
    button(class: 'build-refresh', onclick: :handle_refresh) { 'ログを更新' }
  end

  def status_label
    STATUS_LABELS[props[:build_status]] || props[:build_status].to_s
  end

  def build_log_text
    log = props[:build_log].to_s
    props[:build_log_truncated] ? "…(冒頭は省略)\n#{log}" : log
  end

  # disabled/checked は「属性を付けない/付ける」で切り替える(toolbar.rbのdisabled切り替えと
  # 同じ理由: false を渡す書き方に依存しないため)。組み合わせが多いのでif/elseで愚直に分岐する。
  def render_vm_select
    label(class: 'build-option') do
      span { 'VM' }
      if props[:building]
        tag(:select, ref: :vm_select, onchange: :handle_vm_change, disabled: true) { render_vm_options }
      else
        tag(:select, ref: :vm_select, onchange: :handle_vm_change) { render_vm_options }
      end
    end
  end

  def render_vm_options
    VM_OPTIONS.each do |value, label_text|
      if value == props[:selected_vm]
        tag(:option, value: value, selected: true) { label_text }
      else
        tag(:option, value: value) { label_text }
      end
    end
  end

  def render_usb_console_checkbox
    label(class: 'build-option') do
      render_usb_console_input
      span { 'USB Console(外部UART変換チップなしのボード向け)' }
    end
  end

  def render_usb_console_input
    checked = props[:usb_console]
    disabled = props[:building]

    if disabled && checked
      tag(:input, type: 'checkbox', ref: :usb_console_checkbox, checked: true, disabled: true, onchange: :handle_usb_console_change)
    elsif disabled
      tag(:input, type: 'checkbox', ref: :usb_console_checkbox, disabled: true, onchange: :handle_usb_console_change)
    elsif checked
      tag(:input, type: 'checkbox', ref: :usb_console_checkbox, checked: true, onchange: :handle_usb_console_change)
    else
      tag(:input, type: 'checkbox', ref: :usb_console_checkbox, onchange: :handle_usb_console_change)
    end
  end

  def truthy?(js_value)
    js_value.to_s == 'true'
  end
end
