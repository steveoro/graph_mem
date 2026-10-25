# frozen_string_literal: true

# Vendored from fast-mcp 1.8.0 (https://github.com/yjacquin/fast-mcp, fork https://github.com/steveoro/fast-mcp,
# tag 1.8.0), MIT License, Copyright (c) 2025 Yorick Jacquin. Namespaced under GraphMem::McpSchema;
# the full licence text is in lib/graph_mem/mcp_schema/LICENSE.fast-mcp.

require "dry-schema"
require "addressable/template"
require "base64"

module GraphMem
  # The class-level API graph_mem's MCP tools, prompts and resources are written in, independent of
  # the MCP SDK that serves them:
  # - ToolApi: the `arguments do … end` dry-schema DSL (with `.description`) and its JSON Schema
  #   (`input_schema_to_json`), plus `description`, `annotations` and the validated call;
  # - PromptApi: `prompt_name`, `description`, `argument` and `#messages`;
  # - ResourceApi: `uri` (an RFC 6570 template), `resource_name`, `description`, `mime_type` and `#content`.
  #
  # @example
  #   class EchoTool
  #     include GraphMem::McpSchema::ToolApi
  #     arguments { required(:text).filled(:string).description("Text to echo") }
  #     def call(text:) = text
  #   end
  module McpSchema
  end
end

Dry::Schema.load_extensions(:json_schema)
GraphMem::McpSchema::DrySchemaExtensions.install!
