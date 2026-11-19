Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  root "dashboard#index"
  resources :snapshots, only: %i[index show] do
    post :promote, on: :member
  end
  resources :contracts, only: %i[index show] do
    post :run, on: :member
  end
  resources :drift_events, only: %i[index show] do
    post :acknowledge, on: :member
  end
  resources :suggestions, only: %i[index show] do
    member do
      post :accept
      post :reject
    end
  end

  namespace :api, defaults: { format: :json } do
    namespace :v1 do
      resources :snapshots, only: %i[index show create]
      resources :contracts, only: %i[index show create update] do
        resources :runs, only: :create
        post :heal, on: :member
      end
      resources :runs, only: %i[index show]
      resources :drift_events, only: %i[index show] do
        post :acknowledge, on: :member
      end
      resources :suggestions, only: %i[index show] do
        member do
          post :accept
          post :reject
        end
      end
    end
  end
end
