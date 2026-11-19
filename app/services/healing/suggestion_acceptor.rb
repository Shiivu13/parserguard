module Healing
  # Applies a suggestion to its contract: swaps the selector, bumps the
  # contract version, records a revision, and rejects sibling suggestions
  # for the same field and snapshot so each layout gets one decision per field.
  #
  # Concurrency: the suggestion is claimed atomically (pending -> accepting),
  # and the contract is written through ParserContract.change! (compare-and-set
  # on version), so parallel accepts never double-apply or lose a version.
  class SuggestionAcceptor
    def self.call(suggestion, selector: nil) = new(suggestion, selector).call

    def initialize(suggestion, selector)
      @suggestion = suggestion
      @selector = (selector.presence || suggestion.top_candidate&.fetch("selector", nil)).to_s.strip
    end

    def call
      return Result.failure("suggestion is already #{@suggestion.status}") unless @suggestion.pending?
      return Result.failure("no selector to apply") if @selector.empty?

      reason = Contracts::SelectorPolicy.violation(@selector)
      return Result.failure("selector #{reason}") if reason
      return Result.failure("field #{@suggestion.field_name} no longer exists") if @suggestion.contract.selector_for(@suggestion.field_name).nil?
      return Result.failure("suggestion is already #{@suggestion.reload.status}") unless @suggestion.claim!

      begin
        apply
      rescue StandardError
        @suggestion.release_claim!
        raise
      end
    end

    private

    def apply
      field = @suggestion.field_name
      from = nil
      contract = ParserContract.change!(@suggestion.contract_id) do |doc|
        if @suggestion.container?
          from = doc["container_selector"]
          doc["container_selector"] = @selector
        else
          spec = doc["field_specs"].detect { |f| f["name"] == field }
          from = spec["selector"]
          spec["selector"] = @selector
        end
        { revisions: [ { "field_name" => field, "from_selector" => from, "to_selector" => @selector, "suggestion_id" => @suggestion.id } ] }
      end

      if contract.nil? || contract.errors.any?
        @suggestion.release_claim!
        return Result.failure(contract ? contract.errors.full_messages : "contract no longer exists")
      end

      @suggestion.set(status: "accepted", accepted_selector: @selector, accepted_at: Time.current)
      SelectorSuggestion.pending
                        .where(contract_id: contract.id, field_name: field, snapshot_id: @suggestion.snapshot_id)
                        .not.where(_id: @suggestion.id)
                        .update_all(status: "rejected")
      Result.success(contract)
    end
  end
end
