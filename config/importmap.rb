# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@rails/actioncable", to: "actioncable.esm.js"
pin "cytoscape", to: "cytoscape.js-3.31.4-dist/cytoscape.esm.min.mjs"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
