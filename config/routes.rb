Rails.application.routes.draw do
  resources :events
  resources :accesses
  resources :comments
  resources :todos
  resources :todo_lists
  resources :calendar_events
  resources :calendars
  resources :reports
  resources :projects
  resources :teams
  resources :users
  # For details on the DSL available within this file, see http://guides.rubyonrails.org/routing.html

end
