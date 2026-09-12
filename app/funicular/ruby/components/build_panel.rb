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

  def render
    div(class: 'build-panel') do
      div(class: 'build-panel-header') do
        h1 { 'R2P2-ESP32 Build' }
        render_build_button
        render_refresh_button
        span(class: "build-status #{props[:build_status]}") { status_label }
      end
      tag(:pre, class: 'build-log') { build_log_text }
    end
  end

  def handle_build(event)
    event.preventDefault
    on_build = props[:on_build]
    on_build.call if on_build
  end

  def handle_refresh(event)
    event.preventDefault
    on_refresh = props[:on_refresh]
    on_refresh.call if on_refresh
  end

  private

  def render_build_button
    if props[:building]
      button(class: 'build', disabled: true) { 'ビルド中…' }
    else
      button(class: 'build', onclick: :handle_build) { 'ビルド開始' }
    end
  end

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
end
