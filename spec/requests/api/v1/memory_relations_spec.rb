require 'rails_helper'
require 'swagger_helper'

RSpec.describe 'API V1 Memory Relations', type: :request do
  before { sign_in_operator }

  path '/api/v1/memory_relations' do
    get('list memory relations') do
      tags 'Memory Relations'
      operationId 'listMemoryRelations'
      produces 'application/json'
      parameter name: :from_entity_id, in: :query, type: :integer, required: false, description: 'Filter by source entity ID'
      parameter name: :to_entity_id, in: :query, type: :integer, required: false, description: 'Filter by target entity ID'
      parameter name: :relation_type, in: :query, type: :string, required: false, description: 'Filter by relation type'

      response(200, 'successful') do
        schema type: :array,
               'items': { '$ref' => '#/components/schemas/memory_relation' }

        let!(:entity1) { MemoryEntity.create!(name: 'Entity 1', entity_type: 'TypeA') }
        let!(:entity2) { MemoryEntity.create!(name: 'Entity 2', entity_type: 'TypeB') }
        let!(:entity3) { MemoryEntity.create!(name: 'Entity 3', entity_type: 'TypeC') }
        let!(:relation1) { MemoryRelation.create!(from_entity_id: entity1.id, to_entity_id: entity2.id, relation_type: 'synth_links_to') }
        let!(:relation2) { MemoryRelation.create!(from_entity_id: entity2.id, to_entity_id: entity3.id, relation_type: 'points_at') }
        let!(:relation3) { MemoryRelation.create!(from_entity_id: entity1.id, to_entity_id: entity3.id, relation_type: 'synth_links_to') }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:ok)
          expect(data.size).to be >= 3
        end

        context 'when filtering by from_entity_id' do
          let(:from_entity_id) { entity1.id }
          run_test! do |response|
            data = JSON.parse(response.body)
            expect(data.size).to eq(2)
            expect(data.all? { |rel| rel['from_entity_id'] == entity1.id }).to be true
          end
        end

        context 'when filtering by to_entity_id' do
          let(:to_entity_id) { entity3.id }
          run_test! do |response|
            data = JSON.parse(response.body)
            expect(data.size).to eq(2)
            expect(data.all? { |rel| rel['to_entity_id'] == entity3.id }).to be true
          end
        end

        context 'when filtering by relation_type' do
          let(:relation_type) { 'synth_links_to' }
          run_test! do |response|
            data = JSON.parse(response.body)
            expect(data.size).to eq(2)
            expect(data.all? { |rel| rel['relation_type'] == 'synth_links_to' }).to be true
          end
        end

        context 'when filtering by multiple parameters' do
          let(:from_entity_id) { entity1.id }
          let(:relation_type) { 'synth_links_to' }
          run_test! do |response|
            data = JSON.parse(response.body)
            expect(data.size).to eq(2)
            expect(data.all? { |rel| rel['from_entity_id'] == entity1.id && rel['relation_type'] == 'synth_links_to' }).to be true
          end
        end

        context 'when filter results in no matches' do
          let(:relation_type) { 'non_existent_type' }
          run_test! do |response|
            data = JSON.parse(response.body)
            expect(data.size).to eq(0)
          end
        end
      end
    end

    post('create memory relation') do
      tags 'Memory Relations'
      operationId 'createMemoryRelation'
      consumes 'application/json'
      produces 'application/json'

      parameter name: :memory_relation, in: :body, schema: {
        type: :object,
        properties: {
          from_entity_id: { type: :integer, description: 'ID of the source entity' },
          to_entity_id: { type: :integer, description: 'ID of the target entity' },
          relation_type: { type: :string, example: 'related_to' },
          weight: { type: :number, format: :float, minimum: 0, nullable: true },
          confidence: { type: :number, format: :float, minimum: 0, maximum: 1, nullable: true },
          properties: { type: :object, additionalProperties: true }
        },
        required: [ 'from_entity_id', 'to_entity_id', 'relation_type' ]
      }

      response(201, 'created') do
        schema '$ref' => '#/components/schemas/memory_relation'

        let(:entity_from) { MemoryEntity.create!(name: 'Create From Entity', entity_type: 'CreateFrom') }
        let(:entity_to) { MemoryEntity.create!(name: 'Create To Entity', entity_type: 'CreateTo') }
        let(:memory_relation) do
          {
            from_entity_id: entity_from.id,
            to_entity_id: entity_to.id,
            relation_type: 'points_to',
            weight: 2.5,
            confidence: 0.8,
            properties: { evidence: 'request-spec' }
          }
        end

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:created)
          expect(data['relation_type']).to eq('points_to')
          expect(data['from_entity_id']).to eq(entity_from.id)
          expect(data['to_entity_id']).to eq(entity_to.id)
          expect(data['weight']).to eq(2.5)
          expect(data['confidence']).to eq(0.8)
          expect(data['properties']).to eq('evidence' => 'request-spec')
        end
      end

      response(422, 'unprocessable entity') do
        schema '$ref' => '#/components/schemas/error_response'

        context 'when parent entities do not exist' do
          let(:memory_relation) { { from_entity_id: 9999, to_entity_id: 9998, relation_type: 'non_existent_link' } }

          run_test! do |response|
            data = JSON.parse(response.body)
            expect(response).to have_http_status(:unprocessable_content)
            expect(data['error']).to eq('Validation failed')
            expect(data['details']['from_entity']).to include('must exist')
            expect(data['details']['to_entity']).to include('must exist')
          end
        end

        context 'when relation_type is missing' do
          let(:entity_from) { MemoryEntity.create!(name: 'Create From Entity', entity_type: 'CreateFrom') }
          let(:entity_to) { MemoryEntity.create!(name: 'Create To Entity', entity_type: 'CreateTo') }
          let(:memory_relation) { { from_entity_id: entity_from.id, to_entity_id: entity_to.id, relation_type: nil } }

          run_test! do |response|
            data = JSON.parse(response.body)
            expect(response).to have_http_status(:unprocessable_content)
            expect(data['error']).to eq('Validation failed')
            expect(data['details']['relation_type']).to include("can't be blank")
          end
        end
      end
    end
  end

  path '/api/v1/memory_relations/{id}' do
    parameter name: 'id', in: :path, type: :string, description: 'ID of the Memory Relation'

    let!(:entity1) { MemoryEntity.create!(name: 'Existing Entity 1', entity_type: 'ExistingType1') }
    let!(:entity2) { MemoryEntity.create!(name: 'Existing Entity 2', entity_type: 'ExistingType2') }
    let!(:existing_relation) { MemoryRelation.create!(from_entity_id: entity1.id, to_entity_id: entity2.id, relation_type: 'has_link') }
    let(:id) { existing_relation.id }

    get('show memory relation') do
      tags 'Memory Relations'
      operationId 'showMemoryRelation'
      produces 'application/json'

      response(200, 'successful') do
        schema '$ref' => '#/components/schemas/memory_relation'

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:ok)
          expect(data['id']).to eq(existing_relation.id)
          expect(data['from_entity_id']).to eq(entity1.id)
          expect(data['to_entity_id']).to eq(entity2.id)
          expect(data['relation_type']).to eq('has_link')
        end
      end

      response(404, 'not found') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:id) { 'invalid-relation-id' }

        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end
    end

    patch('update memory relation') do
      tags 'Memory Relations'
      operationId 'patchMemoryRelation'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :memory_relation, in: :body, schema: {
        type: :object,
        properties: {
          relation_type: { type: :string, example: 'updated_link' },
          weight: { type: :number, format: :float, minimum: 0, nullable: true },
          confidence: { type: :number, format: :float, minimum: 0, maximum: 1, nullable: true },
          properties: { type: :object, additionalProperties: true }
        },
        required: []
      }

      response(200, 'successful') do
        schema '$ref' => '#/components/schemas/memory_relation'
        let(:memory_relation) { { relation_type: 'updated_link_patch', confidence: 0.6, properties: { changed: true } } }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:ok)
          expect(data['relation_type']).to eq('updated_link_patch')
          expect(data['confidence']).to eq(0.6)
          expect(data['properties']).to eq('changed' => true)
          reloaded_relation = existing_relation.reload
          expect(reloaded_relation.relation_type).to eq('updated_link_patch')
          expect(reloaded_relation.from_entity_id).to eq(entity1.id)
          expect(reloaded_relation.to_entity_id).to eq(entity2.id)
        end
      end

      response(422, 'unprocessable entity') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:memory_relation) { { relation_type: nil } }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:unprocessable_content)
          expect(data['error']).to eq('Validation failed')
          expect(data['details']['relation_type']).to include("can't be blank")
          expect(existing_relation.reload.relation_type).to eq('has_link')
        end
      end

      response(404, 'not found') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:id) { 'invalid-relation-id' }
        let(:memory_relation) { { relation_type: 'update_attempt_patch' } }

        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end
    end

    put('update memory relation') do
      tags 'Memory Relations'
      operationId 'putMemoryRelation'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :memory_relation, in: :body, schema: {
        type: :object,
        properties: {
          relation_type: { type: :string, example: 'updated_link_put' },
          weight: { type: :number, format: :float, minimum: 0, nullable: true },
          confidence: { type: :number, format: :float, minimum: 0, maximum: 1, nullable: true },
          properties: { type: :object, additionalProperties: true }
        },
        required: [ 'relation_type' ]
      }

      response(200, 'successful') do
        schema '$ref' => '#/components/schemas/memory_relation'
        let(:memory_relation) { { relation_type: 'updated_link_put' } }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:ok)
          expect(data['relation_type']).to eq('updated_link_put')
          reloaded_relation = existing_relation.reload
          expect(reloaded_relation.relation_type).to eq('updated_link_put')
          expect(reloaded_relation.from_entity_id).to eq(entity1.id)
          expect(reloaded_relation.to_entity_id).to eq(entity2.id)
        end
      end

      response(422, 'unprocessable entity') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:memory_relation) { { relation_type: nil } }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:unprocessable_content)
          expect(data['error']).to eq('Validation failed')
          expect(data['details']['relation_type']).to include("can't be blank")
          expect(existing_relation.reload.relation_type).to eq('has_link')
        end
      end

      response(404, 'not found') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:id) { 'invalid-relation-id' }
        let(:memory_relation) { { relation_type: 'update_attempt_put' } }

        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end
    end

    delete('delete memory relation') do
      tags 'Memory Relations'
      operationId 'deleteMemoryRelation'

      response(204, 'no content') do
        run_test! do |response|
          expect(response).to have_http_status(:no_content)
          expect(MemoryRelation.exists?(existing_relation.id)).to be_falsey
        end
      end

      response(404, 'not found') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:id) { 'invalid-relation-id' }

        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end

      response(422, 'part_of delete refused (name collision in the scope the child moves to, or a busy membership lock)') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:parent) { MemoryEntity.create!(name: 'Alpha Project', entity_type: 'Project') }
        let(:child) { MemoryEntity.create!(name: 'SynthWidget', entity_type: 'Component') }
        let!(:part_of) do
          MemoryRelation.create!(from_entity: child, to_entity: parent, relation_type: 'part_of').tap { ProjectMembership.sync!(child) }
        end
        let(:id) { part_of.id }

        # Created once the child sits in the project: the global scope it would move back to is taken.
        before { MemoryEntity.create!(name: 'SynthWidget', entity_type: 'Component') }

        run_test! do |response|
          expect(response).to have_http_status(:unprocessable_content)
          expect(JSON.parse(response.body)['error']).to eq('Validation failed')
          expect(MemoryRelation.exists?(part_of.id)).to be(true)
          expect(child.reload.project_id).to eq(parent.id)
        end
      end
    end
  end

  # R1a: a part_of moves membership. Plain request specs (not rswag): the documented responses are unchanged.
  describe "membership of part_of writes" do
    let(:suffix) { SecureRandom.hex(3) }
    let!(:alpha) { MemoryEntity.create!(name: "Alpha Project #{suffix}", entity_type: "Project") }
    let!(:beta) { MemoryEntity.create!(name: "Beta Project #{suffix}", entity_type: "Project") }
    let!(:widget) { MemoryEntity.create!(name: "SynthWidget #{suffix}", entity_type: "Component") }
    let!(:gear) { MemoryEntity.create!(name: "SynthGear #{suffix}", entity_type: "Component") }

    def create_relation(from, to, type)
      post "/api/v1/memory_relations", params: { memory_relation: { from_entity_id: from.id, to_entity_id: to.id, relation_type: type } },
                                       as: :json
    end

    def body = JSON.parse(response.body)

    describe "POST" do
      it "syncs the child's project for part_of and for a Part Of spelling" do
        create_relation(widget, alpha, "part_of")
        expect(response).to have_http_status(:created)
        create_relation(gear, beta, "Part Of")
        expect(response).to have_http_status(:created)
        expect(body["relation_type"]).to eq("part_of")

        expect([ widget.reload.project_id, gear.reload.project_id ]).to eq([ alpha.id, beta.id ])
      end

      it "refuses a second parent with nothing written" do
        create_relation(widget, alpha, "part_of")

        create_relation(widget, beta, "child_of")

        expect(response).to have_http_status(:unprocessable_content)
        expect(body["error"]).to eq("Validation failed")
        expect(body["details"]["base"].sole).to include("already has a part_of parent")
        expect(MemoryRelation.where(from_entity_id: widget.id).pluck(:to_entity_id)).to eq([ alpha.id ])
        expect(widget.reload.project_id).to eq(alpha.id)
      end

      it "refuses a name collision in the target project with nothing written" do
        MemoryEntity.create!(name: widget.name, entity_type: "Component", project_id: alpha.id)

        create_relation(widget, alpha, "part_of")

        expect(response).to have_http_status(:unprocessable_content)
        expect(body).to include("error" => "Validation failed")
        expect(body["details"]["base"].sole).to include("already exists there")
        expect(MemoryRelation.where(from_entity_id: widget.id)).to be_empty
        expect(widget.reload.project_id).to be_nil
      end

      it "answers a busy membership lock with 422 and nothing written" do
        allow(ProjectMembership).to receive(:with_membership_lock).and_raise(ProjectMembership::LockTimeout, "lock busy")

        create_relation(widget, alpha, "part_of")

        expect(response).to have_http_status(:unprocessable_content)
        expect(body["details"]["base"]).to eq([ "lock busy; retry shortly" ])
        expect(MemoryRelation.where(from_entity_id: widget.id)).to be_empty
      end

      it "takes no lock for another type and behaves as before, the identical relation answering 200" do
        allow(ProjectMembership).to receive(:with_membership_lock).and_call_original

        create_relation(widget, gear, "depends_on")
        expect(response).to have_http_status(:created)
        created = body["id"]
        create_relation(widget, gear, "requires")

        expect(response).to have_http_status(:ok)
        expect(body["id"]).to eq(created)
        expect(ProjectMembership).not_to have_received(:with_membership_lock)
        expect(widget.reload.project_id).to be_nil
      end
    end

    describe "PATCH of the type" do
      def patch_type(relation, type)
        patch "/api/v1/memory_relations/#{relation.id}", params: { memory_relation: { relation_type: type } }, as: :json
      end

      it "syncs the child when the type becomes part_of, and again when it stops being one" do
        relation = MemoryRelation.create!(from_entity: widget, to_entity: alpha, relation_type: "depends_on")

        patch_type(relation, "Part Of")
        expect(response).to have_http_status(:ok)
        expect(relation.reload.relation_type).to eq("part_of")
        expect(widget.reload.project_id).to eq(alpha.id)

        patch_type(relation, "depends_on")
        expect(response).to have_http_status(:ok)
        expect(widget.reload.project_id).to be_nil
      end

      it "refuses a retype into a second parent with nothing written" do
        MemoryRelation.create!(from_entity: widget, to_entity: alpha, relation_type: "part_of")
        ProjectMembership.sync!(widget)
        relation = MemoryRelation.create!(from_entity: widget, to_entity: beta, relation_type: "depends_on")

        patch_type(relation, "part_of")

        expect(response).to have_http_status(:unprocessable_content)
        expect(body["details"]["base"].sole).to include("already has a part_of parent")
        expect(relation.reload.relation_type).to eq("depends_on")
        expect(widget.reload.project_id).to eq(alpha.id)
      end

      it "refuses a retype into part_of that collides in the target project" do
        MemoryEntity.create!(name: widget.name, entity_type: "Component", project_id: alpha.id)
        relation = MemoryRelation.create!(from_entity: widget, to_entity: alpha, relation_type: "depends_on")

        patch_type(relation, "part_of")

        expect(response).to have_http_status(:unprocessable_content)
        expect(body["details"]["base"].sole).to include("already exists there")
        expect(relation.reload.relation_type).to eq("depends_on")
        expect(widget.reload.project_id).to be_nil
      end
    end

    describe "DELETE" do
      let!(:sub) { MemoryEntity.create!(name: "SynthPart #{suffix}", entity_type: "Component") }

      def delete_relation(relation) = delete("/api/v1/memory_relations/#{relation.id}", as: :json)

      def parent_widget(type)
        edge = MemoryRelation.create!(from_entity: widget, to_entity: alpha, relation_type: "synth_placeholder")
        edge.update_column(:relation_type, type)
        MemoryRelation.create!(from_entity: sub, to_entity: widget, relation_type: "part_of")
        [ widget, sub ].each { |entity| ProjectMembership.sync!(entity) }
        expect([ widget.reload.project_id, sub.reload.project_id ]).to eq([ alpha.id, alpha.id ])
        edge
      end

      %w[part_of Part_Of].each do |type|
        it "clears the child's and its subtree's project for a #{type} edge" do
          edge = parent_widget(type)

          delete_relation(edge)

          expect(response).to have_http_status(:no_content)
          expect(MemoryRelation.exists?(edge.id)).to be(false)
          expect([ widget.reload.project_id, sub.reload.project_id ]).to eq([ nil, nil ])
        end
      end

      it "refuses a collision at the scope the child moves to, with nothing deleted" do
        edge = parent_widget("part_of")
        MemoryEntity.create!(name: sub.name, entity_type: "Component")

        delete_relation(edge)

        expect(response).to have_http_status(:unprocessable_content)
        expect(body["details"]["base"].sole).to include("already exists there")
        expect(MemoryRelation.exists?(edge.id)).to be(true)
        expect([ widget.reload.project_id, sub.reload.project_id ]).to eq([ alpha.id, alpha.id ])
      end

      it "answers a busy lock with 422 and nothing deleted" do
        edge = parent_widget("part_of")
        allow(ProjectMembership).to receive(:with_membership_lock).and_raise(ProjectMembership::LockTimeout, "lock busy")

        delete_relation(edge)

        expect(response).to have_http_status(:unprocessable_content)
        expect(body["details"]["base"]).to eq([ "lock busy; retry shortly" ])
        expect(MemoryRelation.exists?(edge.id)).to be(true)
      end

      it "takes no lock for another type and answers 204 as before" do
        edge = MemoryRelation.create!(from_entity: widget, to_entity: gear, relation_type: "depends_on")
        allow(ProjectMembership).to receive(:with_membership_lock).and_call_original

        delete_relation(edge)

        expect(response).to have_http_status(:no_content)
        expect(MemoryRelation.exists?(edge.id)).to be(false)
        expect(ProjectMembership).not_to have_received(:with_membership_lock)
      end
    end
  end
end
