Rails.application.routes.draw do
  mount Rswag::Api::Engine => "/api-docs"
  mount Rswag::Ui::Engine => "/api-docs"
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # API routes
  namespace :api do
    namespace :v1 do
      resources :memory_entities do
        # Nested routes for observations associated with an entity
        resources :memory_observations, only: [ :index, :create, :destroy, :show, :update ]
      end
      # Separate route for searching entities
      resources :memory_entities, only: [] do
        collection do
          get "search"
        end
      end

      # Update memory_relations to include show and update actions
      resources :memory_relations, only: [ :index, :create, :destroy, :show, :update ]
      # Add status endpoint
      get "/status", to: "status#index"
    end
  end

  # Defines the root path route ("/")
  # root "posts#index"
end
