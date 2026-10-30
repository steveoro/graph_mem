# frozen_string_literal: true

# Labels for change sets on Home › Recent activity and System › Activity (audit actor, 1.65.0).
module ChangeSetsHelper
  # @param kind [String] a ChangeSet kind, e.g. "graph.write"
  # @return [String] its label: `change_sets.kinds.<kind>` when the locale has one, else the kind
  #   in words ("graph.write" → "Graph write")
  def change_set_kind_label(kind)
    t("change_sets.kinds.#{kind}", default: kind.to_s.tr("._", "  ").squish.capitalize)
  end

  # @param set [ChangeSet]
  # @param fallback [String] what to show when the set has no actor
  # @return [String] the actor (what the server knows), never the claim
  def change_set_actor_label(set, fallback)
    set.actor.presence || fallback
  end

  # @param claim [String, nil] an actor_claim (self-reported, display only)
  # @return [String, nil] "claimed: …", escaped by the caller's template like any string
  def actor_claim_label(claim)
    t("change_sets.claimed", claim: claim) if claim.present?
  end
end
