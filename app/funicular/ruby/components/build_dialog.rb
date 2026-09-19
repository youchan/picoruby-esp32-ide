# ビルド開始前にVM/USB Consoleを選ばせるダイアログ。
#
# 以前はBuildPanelに常設のフォームとして置いていたが、頻繁に変える設定でも
# ないため「ビルド開始」を押したときだけ選ばせる形に変更した。選択値自体は
# 親(EditorApp)のstate(build_vm / build_usb_console)にあるので、ダイアログを
# 開き直しても前回選んだ値がそのまま残る。
#
# 他のパネルと同じく表示専用。値の変更/確定/キャンセルは
# props[:on_vm_change] / props[:on_usb_console_change] / props[:on_confirm] /
# props[:on_cancel] 経由で親(EditorApp)に委譲する。
class BuildDialog < Funicular::Component
  # 空文字は「現在のCMake設定のデフォルトVMのまま」(idf.py buildにVM未指定)を意味する。
  VM_OPTIONS = [
    ['', 'デフォルト'],
    ['femtoruby', 'FemtoRuby (mruby/c)'],
    ['picoruby', 'PicoRuby (mruby)']
  ].freeze

  def render
    div(class: 'dialog-overlay') do
      div(class: 'dialog build-dialog') do
        h2 { 'ビルドオプション' }
        div(class: 'build-options') do
          render_vm_select
          render_usb_console_checkbox
        end
        div(class: 'dialog-actions') do
          button(class: 'dialog-cancel', onclick: :handle_cancel) { 'キャンセル' }
          button(class: 'dialog-confirm', onclick: :handle_confirm) { 'ビルド開始' }
        end
      end
    end
  end

  def handle_cancel(event)
    event.preventDefault
    on_cancel = props[:on_cancel]
    on_cancel.call if on_cancel
  end

  def handle_confirm(event)
    event.preventDefault
    on_confirm = props[:on_confirm]
    on_confirm.call if on_confirm
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

  def render_vm_select
    label(class: 'build-option') do
      span { 'VM' }
      tag(:select, ref: :vm_select, onchange: :handle_vm_change) { render_vm_options }
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
    if props[:usb_console]
      tag(:input, type: 'checkbox', ref: :usb_console_checkbox, checked: true, onchange: :handle_usb_console_change)
    else
      tag(:input, type: 'checkbox', ref: :usb_console_checkbox, onchange: :handle_usb_console_change)
    end
  end

  def truthy?(js_value)
    js_value.to_s == 'true'
  end
end
