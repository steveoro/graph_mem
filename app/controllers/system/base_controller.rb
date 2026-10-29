# frozen_string_literal: true

module System
  # System (UI-7, the UI plan §2.7): health, settings, backups, access, activity, audit
  # log, telemetry, embeddings, background jobs and the Mission Control queue. Operator only: no
  # subclass calls allow_guest, so a guest gets 403 from every action (RoleAuthorization), and
  # every write keeps ApplicationController's CSRF check.
  #
  # `nav_section` names the sidebar entry a page belongs to (ui/_sidebar reads it from the
  # controller class).
  class BaseController < ApplicationController
    class_attribute :nav_section, instance_writer: false, default: nil
  end
end
