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
  # UI-3: the read-only entity panel (Search's side frame; operators and guests).
  get "entities/:id/panel", to: "entities#panel", as: :entity_panel
  # UI-4b: Explore replaced /graph; old links (scoped_entity_id=, ids=) keep working until §6.D-6.
  get "explore", to: "explore#show", as: :explore
  # Explore's edits (operator only): HTML/Turbo forms, each in an explore.* change set.
  namespace :explore do
    resources :entities, only: [ :update ] do
      post :propose_deletion, on: :member
      resources :observations, only: [ :create ]
    end
    resources :observations, only: [ :update ] do
      post :retire, on: :member
    end
    resources :relations, only: [ :new, :create, :destroy ]
    resources :moves, only: [ :new, :create ]
    resources :merges, only: [ :new, :create ]
  end
  get "graph", to: redirect(status: 301) { |_params, request| "/explore#{"?#{request.query_string}" if request.query_string.present?}" }
  # The Maintenance hub's scan forms post here until §6.D-6; they redirect to the new scan pages.
  resources :project_scans, only: [ :create ]
  resources :project_scan_skills, only: [ :create, :update ]
  # UI-6: Projects & Data (operator only). The Maintenance hub's page redirects (301) until §6.D-6;
  # its #background-jobs / #mcp-clients anchors are forwarded by the projects page.
  get "maintenance", to: redirect("/projects", status: 301), as: :maintenance
  get "projects", to: "projects#index", as: :projects
  namespace :projects do
    resources :scans, only: [ :index, :new, :create, :show ], param: :operation_id do
      get :check_path, on: :collection
    end
    resources :scan_skills, only: [ :update ], param: :operation_id
    # :id is the upload's import session for show (review), execute and destroy (cancel), and the
    # executed import's operation id for report.
    resources :imports, only: [ :index, :new, :create, :show, :destroy ] do
      member do
        post :execute
        get :report
      end
    end
    resources :exports, only: [ :index, :create, :show ], param: :operation_id do
      get :download, on: :member
    end
  end
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
  end

  # UI-7: System (operator only; System::BaseController).
  get "system", to: redirect("/system/settings", status: 301), as: :system
  namespace :system do
    get "settings", to: "settings#show", as: :settings
    patch "settings", to: "settings#update"
    delete "settings/legacy_scan_roots", to: "settings#clear_legacy_scan_roots", as: :clear_legacy_scan_roots

    get "embeddings", to: "embeddings#index", as: :embeddings
    post "embeddings/test_connection", to: "embeddings#test_connection", as: :test_embeddings_connection
    post "embeddings/backfill", to: "embeddings#backfill", as: :backfill_embeddings
    post "embeddings/regenerate", to: "embeddings#regenerate", as: :regenerate_embeddings
    post "embeddings/add_indexes", to: "embeddings#add_indexes", as: :add_embeddings_indexes
    post "embeddings/drop_indexes", to: "embeddings#drop_indexes", as: :drop_embeddings_indexes

    get "telemetry", to: "telemetry#index", as: :telemetry
    post "telemetry/prune", to: "telemetry#prune", as: :prune_telemetry

    get "audit_log", to: "audit_log#index", as: :audit_log
    post "audit_log/prune", to: "audit_log#prune", as: :prune_audit_log

    get "jobs", to: "jobs#index", as: :jobs
    post "jobs/compaction/start", to: "jobs#start_compaction", as: :start_compaction
    post "jobs/compaction/pause", to: "jobs#pause_compaction", as: :pause_compaction
    post "jobs/garbage_collection/run", to: "jobs#run_garbage_collection", as: :run_garbage_collection
    post "jobs/relations/repair", to: "jobs#repair_relations", as: :repair_relations
  end
  # Mission Control (System › Queue). Its base controller is System::QueueDashboardController.
  mount MissionControl::Jobs::Engine, at: "/system/queue"

  # UI-7 shims, until §6.D-6 (drop them all in that PR):
  # - GET 301s: /operator/settings (keeping its query), /operator/embeddings, /operator/telemetry,
  #   /operator/audit_logs, /operator/settings/project_scans/check_path (→ /projects/scans/check_path),
  #   /projects/jobs, /operator/jobs(/*rest) (→ /system/queue/*rest);
  # - the old writes under /operator, routed to the System actions (no copy of the code), so an
  #   open old tab still works.
  keep_query = ->(target) { ->(_params, request) { "#{target}#{"?#{request.query_string}" if request.query_string.present?}" } }
  get "operator/settings", to: redirect(status: 301, &keep_query.call("/system/settings")), as: nil
  get "operator/settings/project_scans/check_path", to: redirect(status: 301, &keep_query.call("/projects/scans/check_path")), as: nil
  get "operator/embeddings", to: redirect("/system/embeddings", status: 301), as: nil
  get "operator/telemetry", to: redirect(status: 301, &keep_query.call("/system/telemetry")), as: nil
  get "operator/audit_logs", to: redirect(status: 301, &keep_query.call("/system/audit_log")), as: nil
  get "projects/jobs", to: redirect("/system/jobs", status: 301), as: nil
  get "operator/jobs(/*rest)", to: redirect(status: 301) { |params, _request| [ "/system/queue", params[:rest] ].compact.join("/") }, as: nil
  scope "operator", module: "system" do
    post "maintenance/compaction/start", to: "jobs#start_compaction", as: nil
    post "maintenance/compaction/pause", to: "jobs#pause_compaction", as: nil
    post "maintenance/garbage_collection/run", to: "jobs#run_garbage_collection", as: nil
    post "maintenance/relations/repair", to: "jobs#repair_relations", as: nil
    post "audit_logs/prune", to: "audit_log#prune", as: nil
    post "telemetry/prune", to: "telemetry#prune", as: nil
    post "embeddings/test_connection", to: "embeddings#test_connection", as: nil
    post "embeddings/backfill", to: "embeddings#backfill", as: nil
    post "embeddings/regenerate", to: "embeddings#regenerate", as: nil
    post "embeddings/add_indexes", to: "embeddings#add_indexes", as: nil
    post "embeddings/drop_indexes", to: "embeddings#drop_indexes", as: nil
    patch "settings", to: "settings#update", as: nil
    post "settings/backup/run", to: "settings#run_backup", as: :operator_run_backup
    post "settings/backup/restore", to: "settings#restore_backup", as: :operator_restore_backup
    delete "settings/backup", to: "settings#destroy_backup", as: :operator_destroy_backup
    delete "settings/project_scans/legacy_roots", to: "settings#clear_legacy_scan_roots", as: nil
  end

  # Defines the root path route ("/")
  root "pages#home"
  # UI-2b: Home's lazy widgets (operator only, status only), one Turbo Frame each.
  get "home/:section", to: "pages#home_section", as: :home_section
end
