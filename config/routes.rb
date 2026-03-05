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
      # Search route defined first to ensure it takes precedence
      get "memory_entities/search", to: "memory_entities#search"

      resources :memory_entities do
        post "merge_into/:target_id", to: "memory_entities#merge", on: :member
        resources :memory_observations, only: [ :index, :create, :destroy, :show, :update ] do
          delete "delete_duplicates", to: "memory_observations#delete_duplicates", on: :collection
        end
      end

      resources :memory_relations, only: [ :index, :create, :destroy, :show, :update ]

      # Context management
      get "/context", to: "context#show"
      post "/context", to: "context#create"
      delete "/context", to: "context#destroy"

      # Subgraph search
      get "/search/subgraph", to: "search#subgraph"
      post "/search/subgraph_by_ids", to: "search#subgraph_by_ids"

      # Bulk operations
      post "/bulk", to: "bulk#create"

      # Maintenance and stats
      get "/maintenance/suggest_merges", to: "maintenance#suggest_merges"
      get "/maintenance/stats", to: "maintenance#stats"

      # Status and utilities
      get "/status", to: "status#index"
      get "/time", to: "status#time"

      # Graph data endpoint
      get "graph_data", to: "graph_data#index"
    end
  end

  # Data Exchange routes for import/export and cleanup
  resources :data_exchange, only: [] do
    collection do
      # Export routes (sync and async)
      get :export              # Sync export (direct download)
      post :export_async       # Async export with progress (starts job)
      get :download_export     # Download completed async export
      get :root_nodes

      # Import routes
      post :import_upload
      get :import_review
      post :import_execute
      get :import_report
      delete :import_cancel

      # Cleanup routes
      get :orphan_nodes
      post :move_node
      post :merge_node
      delete :delete_node

      # Relation management routes
      get :duplicate_relations
      delete :delete_duplicate_relations
      patch :update_relation
      delete :delete_relation
    end
  end

  get "search", to: "search#results"

  # Defines the root path route ("/")
  root "pages#home"
end
