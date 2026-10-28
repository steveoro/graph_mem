Rails.application.routes.draw do
  # /api-docs (Rswag) is restricted to authenticated operators.
  constraints(OperatorSessionConstraint.new) do
    mount Rswag::Api::Engine => "/api-docs"
    mount Rswag::Ui::Engine => "/api-docs"
  end

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Serve WebSocket cable requests for real-time progress updates
  mount ActionCable.server => "/cable"

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # CSP violation reports (CSP enforced since 1.56.0)
  post "csp-reports", to: "csp_reports#create"

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

      # Project source scan
      post "scan", to: "scan_projects#create"
      get "scan/:id", to: "scan_projects#show", as: :scan_project
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

      # Entity autocomplete for the Review page's edit fields
      get :entity_search

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
  resources :project_scans, only: [ :create ]
  resources :project_scan_skills, only: [ :create, :update ]
  get "maintenance", to: "maintenance#index"
  # UI-5b: Review & Fix (operator only). The old review page's URL redirects (301).
  get "data_exchange/compaction_review",
      to: redirect(status: 301) { |_params, request| request.params[:report_type] == "scan_review" ? "/review?view=scan" : "/review" }
  get "review", to: "review#index", as: :review
  scope "review", controller: "review", as: "review" do
    get "group", action: :group, as: :group
    get "group/preview", action: :group_preview, as: :group_preview
    post "group/apply", action: :group_apply, as: :group_apply
    post "group/dismiss", action: :group_dismiss, as: :group_dismiss
    post "group/snooze", action: :group_snooze, as: :group_snooze
    post "policies/run", action: :run_policies, as: :run_policies
    post "import_suggest_merges", action: :import_suggest_merges, as: :import_suggest_merges
    get "rows/:uuid", action: :show, as: :row
    patch "rows/:uuid", action: :update
    get "rows/:uuid/preview", action: :preview, as: :row_preview
    post "rows/:uuid/apply", action: :apply, as: :row_apply
    post "rows/:uuid/dismiss", action: :dismiss, as: :row_dismiss
    post "rows/:uuid/snooze", action: :snooze, as: :row_snooze
    post "rows/:uuid/restore", action: :restore, as: :row_restore
  end
  # UI-4a: operator-only undo of a recorded change set.
  resources :changes, only: [], param: :uuid do
    post :undo, on: :member
  end

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

    get "telemetry", to: "telemetry#index", as: :telemetry
    post "telemetry/prune", to: "telemetry#prune", as: :prune_telemetry

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
    get "settings/project_scans/check_path", to: "settings#check_scan_path", as: :check_scan_path
    delete "settings/project_scans/legacy_roots", to: "settings#clear_legacy_scan_roots", as: :clear_legacy_scan_roots
  end

  mount MissionControl::Jobs::Engine, at: "/operator/jobs"

  # Defines the root path route ("/")
  root "pages#home"
  # UI-2b: Home's lazy widgets (operator only, status only), one Turbo Frame each.
  get "home/:section", to: "pages#home_section", as: :home_section
end
