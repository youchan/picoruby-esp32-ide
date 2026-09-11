# サイドバーのファイル一覧。
#
# 状態を持たない表示専用コンポーネント。
# 一覧データも選択中パスも親(EditorApp)から props で受け取り、
# クリックされたら props[:on_select] を呼び返すだけにしている。
class FileList < Funicular::Component
  def render
    files = props[:files] || []

    div(class: 'file-list-section') do
      h1 { 'Project Files' }
      ul(class: 'file-list') do
        if props[:loading]
          li(class: 'loading') { '読み込み中…' }
        elsif files.empty?
          li(class: 'empty') { '編集できるファイルがありません' }
        else
          files.each do |path|
            render_item(path)
          end
        end
      end
    end
  end

  private

  def render_item(path)
    ext = extension(path)
    classes = (path == props[:current_path]) ? 'active' : ''

    li(key: path, class: classes, onclick: select_handler(path)) do
      span(class: "file-icon #{ext}") { ext }
      span(class: 'file-name') { path }
    end
  end

  # render 時点の path を lambda に閉じ込めて渡す。
  # (onclick: :method_name 形式だと、どのファイルが押されたか伝えられないため)
  def select_handler(path)
    -> { props[:on_select].call(path) }
  end

  def extension(path)
    parts = path.to_s.split('.')
    parts.length > 1 ? parts.last.to_s : ''
  end
end
