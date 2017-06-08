# tower-events
Events System of Tower.im

[![Build Status](https://travis-ci.org/dylanninin/tower-events.svg?branch=master)](https://travis-ci.org/dylanninin/tower-events)

# Design

抽象模型。主要参考 [JSON Activity Streams 1.0](http://activitystrea.ms/specs/json/1.0/)。

event 可以抽象为：`[someone] [did an action] [on|with an object] [to|against a target] [at a time] [within some contexts]`

- actor：即 [someone]，产生该事件的主体，可以是任意实体；一般为用户
- verb：即 [did an action]，描述该事件的具体动作，如 `create`, `assign`, `reply` 等
- object：即 [on|with an object]，描述该事件的首要对象，比如 `someone created a todo` 中的 `a todo`, `someone assigned a todo to an assignee` 中的 `a todo`
- target：即 `[to|against a target]`，描述该事件的目标对象，可根据具体的 `verb` 进行解释，如 `someone assigned a todo to an assignee` 中的 `an assignee`, `someone replied a comment to a todo` 中的 `todo`
- `provider`：即产生该事件的应用上下文，可选。例如，以上 `event` 均是用户在某一个 `team` 下生成的，属于所有 `team` 成员共有，此时 `generator` 为该 `team`
- `generator`：即发布该事件的应用上下文，根据 `object + target` 确定，可选。例如，以上某些 `event` 是用户在某一个 `context` 下生成的，比如 `todo/comment` 等从属于 `project` 时，此时 `provider` 为 `project`
- `published`：即 `[at a time]`，描述该事件产生的时间。
- `title`：即该事件的字面标题，一般根据 `actor + verb + object + target + published` 组成，可以灵活展示；可选。
- `content`：即该事件的具体内容，一般根据 `object + target` 组成，可以灵活展示；可选。

针对修改 `model` 中的某些字段，同时带有重要语义的情况，如 `assign a todo to someone`, `change the due_to of a todo`等等，抽象处理成更新 `object`，在 `object` 中增加字段 `audited` 来标记这种变更。如下：`audited` 单独封装成一个 `hash`，event[object][audited] 如：

```ruby
"audited": {
"attribute": "due_to",
"old_value": nil,
"new_value": "2017-06-03"
}
```

主要变更历史
- `audited`: 原先为 `event[object][audited_attribute]`, `event[object][old_value]`, `event[object][new_value]`，现在统一封装到 `audited` 中
- `published`: 最初时间的创建时间使用 `created_at` 字段，但与一般数据库记录的创建时间冲突，语义上不等价；另外，在异步创建时间时，两者相差更远。故增加 `published` 字段
- `title`, `content`: 可以移除掉，暂无处理。

参考
- [#2 系统设计](https://github.com/dylanninin/tower-events/issues/2)
- [JSON Activity Streams 1.0](http://activitystrea.ms/specs/json/1.0/)

# Implementation

主要利用 `rails` 提供的机制：
- `callbacks`:  实现生成 `event` 的同步回调

`Event` model 设计
- 旨在提供生成 `event` 的唯一的入口，提供定制化参数，实现可插拔的 `event`
- `create_event`: 即创建 `event` 的统一入口
  - `actor`：Object, required. 指定 event.actor, 即当前操作者
  - `verb`: String, required, 指定 event.verb
  - `object`: Object, required. 指定 event.object，即当前操作的首要对象
  - `target`：Object, optional. 指定 event.target，即当前操作的目标对象
  - `provider`: Object, optional. 指定 event.provider, 属于 Context
  - `generator`: Object, optional. 指定 event.generator, 属于 Context
  - `changed_attribute`: Hash，因属性取值变化而产生的事件，如修改Todo的完成事件、完成者等
    - => `name`. 即要跟踪变化的属性.
    - => `alias`. 属性别名，若不指定默认为 name 取值。例如 name: :assignee_id, alias: :assignee，则在 audited[attribute] = :assignee
    - => `old_value?`：Proc. 指定数据属性取值变化时，旧的取值是否满足当前 verb 的要求。如 open|reopen|complete 等动作均是对 Todo.status 属性操作，此时需要验证以作区分。
    - => `new_value?`：Proc. 指定数据属性取值变化时，新的取值是否满足当前 verb 的要求。如 open|reopen|complete 等动作均是对 Todo.status 属性操作，此时需要验证以作区分。
    - => `value_proc`：Proc. 指定 event.object.audited 中 old|new_value 的求值 proc，若不指定默认为原始
- `as_partial_event`：即将上述 Object 序列化成 `event` 属性的方法，使用 `as_json` 方法
- `find_by`：提供事件的查询方法

以 `Todo` 为例，没有 `events` 动态之前：
```ruby
class Todo < ApplicationRecord
  enum status: { open: 0, running: 1, paused: 2, completed: 3 }

  belongs_to :assignee, class_name: 'User', optional: true
  belongs_to :todo_list
  belongs_to :project
  belongs_to :team
  belongs_to :creator, class_name: 'User'
end
```

要增加 `创建`、`设置完成者` 等`events`动态，需要创建 callback，并调用 `Event.create_event` 方法即可，代码如下：
```ruby
class Todo < ApplicationRecord
  enum status: { open: 0, running: 1, paused: 2, completed: 3 }

  belongs_to :assignee, class_name: 'User', optional: true
  belongs_to :todo_list
  belongs_to :project
  belongs_to :team
  belongs_to :creator, class_name: 'User'

  after_create_commit :add_event_after_create
  def add_event_after_create
    Event.create_event actor: User.current, verb: :create, object: self,
                       provider: project, generator: team
  end

  around_update :add_event_after_assign
  def add_event_after_assign
    yield
    changed_attribute = {
      name: :assignee_id,
      alias: :assignee,
      old_value?: ->(v) { v.nil? },
      value_proc: ->(v) { User.where(id: v).first }
    }
    Event.create_event actor: User.current, verb: :assign, object: self,
                       target: assignee, changed_attribute: changed_attribute,
                       provider: project, generator: team
  end
end
```

特别地，创建事件时，`todo` 会默认调用 `as_json` 方法序列化全部属性；若想定制，定义 `as_partial_event` 方法即可，如下：

```ruby
class Todo < ApplicationRecord
  # ...
  # Serialize as partial event
  def as_partial_event
    as_json only: %i[name], include: { creator: { only: %i[:id name avatar] }}
  end
  # ...
```

不足之处
- 实现受限于 `rails` 的 callback 机制
- 对比 `assignee`,`set_due_to`(即 `audited`）的设计、实现，其实与其他 `verb` 很不一致，之前的考虑见  https://github.com/dylanninin/tower-events/issues/2#issuecomment-305469983   

源代码
- `Event`: [app/models/event.rb](app/models/event.rb)
- `Todo`: [app/models/todo.rb](app/models/todo.rb)

主要变更历史
- `destroy`：数据库使用 `paranoid` 实现 soft delete，但其内部的实现为 `update_columns`，不会触发 `callback`，故采用 `update_attributes` 的方式实现
- 在 `audited` 中需要获取引用对象，而非 `id` 值。如 `todo.assignee`，受限于 `rails` 的 `change` 机制，默认保存的 `audited` 信息如下：

  ```ruby
  "audited": {
  "attribute": "assignee_id",
  "old_value": nil,
  "new_value": 1
  }
  ```

  对 `event` 来说，信息不充分。故，增加 `value_proc` 选项，即一个 `proc`，可以对默认的 `old|new_value` 进行求值，此时 `audited` 信息如下：

  ```ruby
  "audited": {
    "attribute": "assignee",
    "old_value": nil,
    "new_value": {
      "id": 1,
      "type": "User",
      "name": "dylan",
      "avatar": "the_url_of_avatar"
    }
  }
  ```

参考
- http://guides.rubyonrails.org/active_record_callbacks.html
- https://github.com/rails/rails/pull/21114
- [#8 Event实现](https://github.com/dylanninin/tower-events/issues/8)

# Views

根据要求：
- `events` 先按照日期聚合，日期内再按照连续的项目、日历或者周报（即 `provider`）来聚合，即有嵌套分组。`EventsController`: [app/controllers/events_controller.rb](app/controllers/events_controller.rb)
  - 数据库仅查询、分页
  - 分组使用代码实现
  - 为使得结构简单、一直，返回的数据的分组 `group` 均为 `event` 本身
- `events` 页面可以持续加载，目前参考 jquery-infinite-pages 实现

实现说明：
- 目前列出的是所有 `events`，没有按照 `user`, `team` 进行筛选；若要筛选，可以使用 `Event.find_by` 方法
- 目前动态内容暂未国际化、本地化，如 `verb` 结合语义的翻译等
- 下拉持续加载时，若下一页的分组日期与当前页相同时，尚未做合并

参考
- https://github.com/magoosh/jquery-infinite-pages
- [#9 UI 实现 - 动态页面](https://github.com/dylanninin/tower-events/issues/9)

# Testing

- seed: [db/seeds.rb](db/seeds.rb)
- spec: [spec/models/todo_rspec.rb](spec/models/todo_spec.rb)

# Demo

localhost, open http://localhost:3000/events after doing following steps
- `rails db:create`
- `rails db:migrate`
- `rails db:seed`
- `rails s`

online: https://awesome-tower-events.herokuapp.com/

参考
- https://devcenter.heroku.com/articles/getting-started-with-rails5
- https://devcenter.heroku.com/articles/using-multiple-buildpacks-for-an-app
- https://devcenter.heroku.com/articles/pre-provision-database

# Indexing

目前 `events` 的使用场景，主要是：

- 一个 team 的所有动态。即 filter by generator 是一个常见操作
- 一个 object 的所有动态，包含 object + target
  - 比如 一个 todo 的所有主要变更记录，如创建、删除、完成、修改完成者/时间，即 filter by object 是一个常见操作
  - 比如 一个 todo 的所有回复操作，此时不需要展示此类动态，直接查询 `comments` 即可。即暂无 filter by target 的需求
- 以上需求中，所有动态需要按发生时间排序。即 order by published 是一个常见操作

故主要针对以上场景建立索引，提升查询效率，见 [add_indices_to_events.rb](db/migrate/20170605012650_add_indices_to_events.rb)

# One more thing

review history
- 实现过于复杂，代码不好读懂
- model 层要『轻量』，只负责属性的读取和存储
- 创建 event 属于 业务层，不应该是 model 层负责；可以放在 controller 或 service 层
- 参考 [public-activity](https://github.com/chaps-io/public_activity)

result: failed this test
