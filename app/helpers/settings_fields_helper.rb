# frozen_string_literal: true

# The inputs of a SettingsSchema field (UI-7 S3), used by system/settings/_field. Every input is
# named `settings[<key>]`, has the id `setting_<key>` and the testid `setting-<key>`.
module SettingsFieldsHelper
  # @param field [SettingsSchema::Field]
  # @return [Object] the value to show: the posted one after a refused save, else the stored one
  def settings_field_value(field)
    return @posted_settings[field.key] if @posted_settings&.key?(field.key)

    AppSettings.public_send(field.key)
  end

  # @param field [SettingsSchema::Field]
  # @param value [Object] see {#settings_field_value}
  # @return [ActiveSupport::SafeBuffer] the input for the field's type (or its `input`)
  def settings_field_input(field, value)
    name = "settings[#{field.key}]"
    options = { id: "setting_#{field.key}", class: "ui-input", disabled: field.readonly, data: { testid: "setting-#{field.key}" },
                aria: { describedby: "setting_#{field.key}_help" } }
    return settings_slider(field, value, options) if field.input == :slider

    case field.input || field.type
    when :select
      select_tag name, options_for_select([ [ t("system.settings.blank_option"), "" ] ] + field.choices.map { |choice| [ choice, choice ] }, value), options
    when :textarea then text_area_tag name, value, options.merge(rows: 3)
    when :integer, :float
      number_field_tag name, value, options.merge(min: field.range&.min, max: field.range&.max, step: field.type == :float ? "any" : 1)
    else text_field_tag name, value, options.merge(placeholder: (t("system.settings.blank_uses_env") if field.fallback))
    end
  end

  # @param field [SettingsSchema::Field] a boolean field
  # @param value [Object] see {#settings_field_value}
  # @return [Boolean]
  def settings_field_checked?(field, value)
    @posted_settings&.key?(field.key) ? SettingsSchema.cast(field, value) : value == true
  end

  private

  def settings_slider(field, value, options)
    tag.div(class: "system-slider", data: { controller: "import-threshold" }) do
      safe_join([
        range_field_tag("settings[#{field.key}]", value, options.merge(min: field.range.min, max: field.range.max, step: 0.01,
                                                                        data: options[:data].merge(action: "input->import-threshold#sync",
                                                                                                   import_threshold_target: "slider"))),
        tag.output(format("%.2f", value.to_f), class: "system-slider__value",
                                               data: { import_threshold_target: "output", testid: "import-observation-duplicate-distance-value" })
      ])
    end
  end
end
