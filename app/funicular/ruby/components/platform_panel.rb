# プラットフォーム(ターゲットチップ)セットアップパネル。
#
# ボタンを押すとサーバ側で `rake setup_#{platform}` が実行される
# (R2P2-ESP32/rakelib/setup.rake の setup_esp32 / setup_esp32c3 / ... タスク)。
# deep_clean + mrubyの再ビルド + idf.py set-target という重い処理なので、
# 実行中は全ボタンを無効化する。
#
# 他のパネルと同じく表示専用。実行/ログ更新は props[:on_select] / props[:on_refresh]
# 経由で親(EditorApp)に委譲する。
class PlatformPanel < Funicular::Component
  PLATFORMS = %w[esp32 esp32c3 esp32c6 esp32h2 esp32p4 esp32s3]

  STATUS_LABELS = {
    'idle' => '未実行',
    'running' => 'セットアップ中…',
    'success' => 'セットアップ完了',
    'failed' => 'セットアップ失敗'
  }

  def render
    div(class: 'platform-panel') do
      div(class: 'platform-panel-header') do
        h1 { 'Platform Setup' }
        span(class: 'platform-target') { props[:selected_platform] || '未選択' }
        render_refresh_button
        span(class: "build-status #{props[:platform_status]}") { status_label }
      end
      tag(:pre, class: 'build-log') { log_text }
    end
  end

  def handle_refresh(event)
    event.preventDefault
    on_refresh = props[:on_refresh]
    on_refresh.call if on_refresh
  end

  private

  def render_refresh_button
    button(class: 'build-refresh', onclick: :handle_refresh) { 'ログを更新' }
  end

  def status_label
    STATUS_LABELS[props[:platform_status]] || props[:platform_status].to_s
  end

  def log_text
    log = props[:platform_log].to_s
    props[:platform_log_truncated] ? "…(冒頭は省略)\n#{log}" : log
  end
end
