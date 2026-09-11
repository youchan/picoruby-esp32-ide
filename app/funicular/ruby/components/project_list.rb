# サイドバー上部のプロジェクト一覧。
#
# FileList と同じく状態を持たない表示専用コンポーネント。
# 一覧データも選択中プロジェクトも親(EditorApp)から props で受け取り、
# クリックされたら props[:on_select] を呼び返すだけにしている。
class ProjectList < Funicular::Component
  def render
    projects = props[:projects] || []

    div(class: 'project-list-section') do
      h1 { 'Projects' }
      ul(class: 'project-list') do
        if props[:loading]
          li(class: 'loading') { '読み込み中…' }
        elsif projects.empty?
          li(class: 'empty') { 'プロジェクトがありません' }
        else
          projects.each { |name| render_item(name) }
        end
      end
    end
  end

  private

  def render_item(name)
    classes = (name == props[:current_project]) ? 'active' : ''
    li(key: name, class: classes, onclick: select_handler(name)) { name }
  end

  # render 時点の name を lambda に閉じ込めて渡す。
  # (onclick: :method_name 形式だと、どのプロジェクトが押されたか伝えられないため)
  def select_handler(name)
    -> { props[:on_select].call(name) }
  end
end
