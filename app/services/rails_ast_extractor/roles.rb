# frozen_string_literal: true

class RailsAstExtractor
  # The Rails role of a declared constant (1.74.0): which GraphVocabulary type a Rails convention
  # makes it, instead of the generic Class or Module. Pure: RailsAstExtractor and the scan's code
  # map both use it. Rules, first match wins:
  #
  # 1. A module under an `app/<dir>/concerns/` root, or one that does `extend ActiveSupport::Concern`:
  #    Concern.
  # 2. The **main constant** of a file under a Zeitwerk root `app/<dir>/` (the one its path names:
  #    app/models/goggles_db/badge.rb declares GogglesDb::Badge) takes DIR_ROLES[dir]. A module there
  #    is a namespace (Module), except in helpers, where modules are the helpers.
  # 3. A class whose superclass chain reaches a SUPERCLASS_ROLES name (lib/, other dirs, a nested
  #    class): that role.
  # 4. Otherwise the declared kind, Class or Module.
  #
  #   Roles.dir_role("app/strategies/goggles_db/importers/badge.rb", "GogglesDb::Importers::Badge", "Class") # => "Strategy"
  #   Roles.superclass_role("ActiveRecord::Base") # => "Model"
  module Roles
    # `app/<dir>` => the role of its files' main constants.
    DIR_ROLES = {
      "models" => "Model", "controllers" => "Controller", "helpers" => "Helper", "jobs" => "Job", "mailers" => "Mailer",
      "decorators" => "Decorator", "validators" => "Validator", "services" => "Service", "strategies" => "Strategy",
      "commands" => "Command", "components" => "Component", "api" => "APIEndpoint"
    }.freeze
    # External superclasses (and the Rails application bases) => the role of their subclasses.
    SUPERCLASS_ROLES = {
      "ActiveRecord::Base" => "Model", "ApplicationRecord" => "Model",
      "ActionController::Base" => "Controller", "ActionController::API" => "Controller", "ActionController::Metal" => "Controller",
      "ApplicationController" => "Controller",
      "ActiveJob::Base" => "Job", "ApplicationJob" => "Job",
      "ActionMailer::Base" => "Mailer", "ApplicationMailer" => "Mailer",
      "ActiveModel::Validator" => "Validator", "ActiveModel::EachValidator" => "Validator",
      "ViewComponent::Base" => "Component", "Draper::Decorator" => "Decorator",
      "Grape::API" => "APIEndpoint", "Grape::API::Instance" => "APIEndpoint"
    }.freeze
    CONCERN = "ActiveSupport::Concern"
    CONCERNS_DIR = "concerns"
    # How far a superclass chain is followed through the project's own classes.
    MAX_CHAIN = 10

    module_function

    # @param file [String] the declaring file, relative to the repo root
    # @param qualified [String] the constant's qualified name
    # @param kind [String] "Class" or "Module", as declared
    # @return [String, nil] the role rules 1 (concerns dir) and 2 give, nil when they don't apply
    def dir_role(file, qualified, kind)
      root, dir = zeitwerk_root(file)
      return nil unless root && main_constant?(file, root, qualified)
      return (kind == "Module" ? "Concern" : nil) if dir == CONCERNS_DIR

      role = DIR_ROLES[dir]
      return nil unless role
      return "Module" if kind == "Module" && dir != "helpers"

      role
    end

    # @param name [String] a superclass name as written (`::ActiveRecord::Base` or `ActiveRecord::Base`)
    # @return [String, nil]
    def superclass_role(name)
      SUPERCLASS_ROLES[name.to_s.delete_prefix("::")]
    end

    # @return [Array(String, String), nil] the Zeitwerk root of a file and its directory name:
    #   ["app/models", "models"], ["app/models/concerns", "concerns"] or ["lib", nil]
    def zeitwerk_root(file)
      parts = file.to_s.split("/")
      if parts[0] == "app" && parts.size >= 3
        return [ "app/#{parts[1]}/#{CONCERNS_DIR}", CONCERNS_DIR ] if parts[2] == CONCERNS_DIR && parts.size >= 4

        [ "app/#{parts[1]}", parts[1] ]
      elsif parts[0] == "lib" && parts.size >= 2
        [ "lib", nil ]
      end
    end

    # @return [Boolean] the constant is the one the file's path names, either way round:
    #   `GogglesDB::APIClient` underscores to `goggles_db/api_client` (an acronym inflection), and
    #   `goggles_db/best_50m_result` camelizes to `GogglesDb::Best50mResult` (a digit, which
    #   `"Best50mResult".underscore` doesn't split back)
    def main_constant?(file, root, qualified)
      path = file.to_s.delete_prefix("#{root}/").delete_suffix(".rb")
      qualified.to_s.underscore == path || path.camelize == qualified.to_s
    end
  end
end
