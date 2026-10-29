# frozen_string_literal: true

# The Projects list (UI-6 P2): one page of Project roots, each with its last scan, its last
# import and its pending scan-review groups, in a fixed number of queries whatever the page holds.
#
#   overview = ProjectsOverview.new(page: params[:page])
#   overview.projects   # => the Kaminari page of Project roots, by name
#   overview.rows       # => [#<data Row project=…, last_scan=<OperationProgress>, last_import=nil, review_groups=2>, …]
class ProjectsOverview
  PER_PAGE = 50
  SCAN_TYPES = %w[project_scan project_scan_skill].freeze
  IMPORT_TYPES = %w[import].freeze

  Row = Data.define(:project, :last_scan, :last_import, :review_groups)

  # An operation belongs to a project by details.project_entity_id, or (before a scan records the
  # id) by details.project_name.
  ENTITY_ID_SQL = "JSON_VALUE(operation_progresses.details, '$.project_entity_id')"
  NAME_SQL = "JSON_VALUE(operation_progresses.details, '$.project_name')"

  # @param page [Integer, String, nil] 1-based
  def initialize(page: 1)
    @page = page
  end

  # @return [ActiveRecord::Relation] Project roots (no project of their own), paged
  def projects
    @projects ||= MemoryEntity.where(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE, project_id: nil)
                              .order(:name, :id).page(@page).per(PER_PAGE)
  end

  # @return [Array<Row>]
  def rows
    list = projects.to_a
    scans = latest_operations(SCAN_TYPES, list)
    imports = latest_operations(IMPORT_TYPES, list)
    groups = review_groups(list.map(&:id))
    list.map do |project|
      Row.new(project: project, last_scan: newest_for(project, scans), last_import: newest_for(project, imports),
              review_groups: groups.fetch(project.id, 0))
    end
  end

  private

  # The newest operation per id key and per name key (so at most two per project), in one query.
  def latest_operations(types, list)
    return [] if list.empty?

    key = "COALESCE(#{ENTITY_ID_SQL}, CONCAT('name:', #{NAME_SQL}))"
    ranked = OperationProgress.where(operation_type: types)
                              .where("#{ENTITY_ID_SQL} IN (?) OR (#{ENTITY_ID_SQL} IS NULL AND #{NAME_SQL} IN (?))",
                                     list.map { |project| project.id.to_s }, list.map(&:name))
                              .select("operation_progresses.*, ROW_NUMBER() OVER (PARTITION BY #{key} " \
                                      "ORDER BY operation_progresses.created_at DESC, operation_progresses.id DESC) AS position")
    OperationProgress.from(ranked, :operation_progresses).where(position: 1).to_a
  end

  def newest_for(project, operations)
    operations.select { |operation| belongs_to?(operation, project) }.max_by { |operation| [ operation.created_at, operation.id ] }
  end

  def belongs_to?(operation, project)
    details = operation.details || {}
    return details["project_entity_id"].to_s == project.id.to_s if details["project_entity_id"].present?

    details["project_name"].to_s == project.name.to_s
  end

  # Pending scan-review groups per project (the Review page's grouping), in one grouped count.
  def review_groups(ids)
    return {} if ids.empty?

    MaintenanceReportRow.active.where(report_type: "scan_review", project_id: ids).group(:project_id)
                        .distinct.count(Arel.sql(ReviewDigest::GROUP_SQL))
  end
end
