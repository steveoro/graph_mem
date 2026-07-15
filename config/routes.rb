Rails.application.routes.draw do
  mount Rswag::Api::Engine => "/api-docs"
  mount Rswag::Ui::Engine => "/api-docs"
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Serve WebSocket cable requests for real-time progress updates
  mount ActionCable.server => "/cable"

  # Reveal health status on /up that r
  # eturns 200 if the app boots with no exceptions, otherwise 500.
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
          get "rank", to: "memory_observations#rank", on: :collection
          post "detect_contradictions", to: "memory_observations#detect_contradictions", on: :collection
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

      get "/graph/traverse", to: "graph_traversal#traverse"
      get "/graph/shortest_path", to: "graph_traversal#shortest_path"

      post "summarize", to: "summaries#create"
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

      # Compaction review routes
      get :compaction_review
      post :compaction_review_action

      # Cleanup routes
      get :orphan_nodes
      post :move_node
      post :merge_node
      delete :delete_node

      # Relation management routes
      get :duplicate_relations
      delete :delete_duplicate_relations
      post :create_relation
      patch :update_relation
      delete :delete_relation
    end
  end

  get "search", to: "search#results"
  get "graph", to: "pages#graph"
  get "maintenance", to: "maintenance#index"

  namespace :operator do
    get "login", to: "sessions#new", as: :login
    post "login", to: "sessions#create", as: :session
    delete "logout", to: "sessions#destroy", as: :logout

    post "maintenance/compaction/start", to: "maintenance#start_compaction", as: :start_compaction
    post "maintenance/compaction/pause", to: "maintenance#pause_compaction", as: :pause_compaction
    post "maintenance/garbage_collection/run", to: "maintenance#run_garbage_collection", as: :run_garbage_collection
    post "maintenance/relations/repair", to: "maintenance#repair_relations", as: :repair_relations

    get "audit_logs", to: "audit_logs#index", as: :audit_logs
    post "audit_logs/prune", to: "audit_logs#prune", as: :prune_audit_logs

    get "embeddings", to: "embeddings#index", as: :embeddings
    post "embeddings/test_connection", to: "embeddings#test_connection", as: :test_embeddings_connection
    post "embeddings/backfill", to: "embeddings#backfill", as: :backfill_embeddings
    post "embeddings/regenerate", to: "embeddings#regenerate", as: :regenerate_embeddings
    post "embeddings/add_indexes", to: "embeddings#add_indexes", as: :add_embeddings_indexes
    post "embeddings/drop_indexes", to: "embeddings#drop_indexes", as: :drop_embeddings_indexes

    get "settings", to: "settings#index", as: :settings
    patch "settings", to: "settings#bulk_update", as: :settings_bulk_update
    post "settings/backup/run", to: "settings#run_backup", as: :run_backup
    post "settings/backup/restore", to: "settings#restore_backup", as: :restore_backup
    delete "settings/backup", to: "settings#destroy_backup", as: :destroy_backup
  end

  mount MissionControl::Jobs::Engine, at: "/operator/jobs"

  # Defines the root path route ("/")
  root "pages#home"
end
