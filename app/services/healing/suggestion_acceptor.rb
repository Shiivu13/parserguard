module Healing
  # Applies a suggestion to its contract: swaps the selector, bumps the
  # contract version, records a revision, and rejects sibling suggestions
  # for the same field and snapshot so each layout gets one decision per field.
  class SuggestionAcceptor
    def self.call(suggestion, selector: nil) = new(suggestion, selector).call

    def initialize(suggestion, selector)
      @suggestion = suggestion
      @selector = (selector.presence || suggestion.top_candidate&.fetch("selector", nil)).to_s.strip
    end

    def call
      return Result.failure("suggestion is already #{@suggestion.status}") unless @suggestion.pending?
      return Result.failure("no selector to apply") if @selector.empty?
      return Result.failure("invalid CSS selector: #{@selector}") unless valid_css?

      contract = @suggestion.contract
      from = contract.selector_for(@suggestion.field_name)
      return Result.failure("field #{@suggestion.field_name} no longer exists") if from.nil?

      apply(contract)
      contract.version += 1
      contract.revisions << ContractRevision.new(
        field_name: @suggestion.field_name, from_selector: from, to_selector: @selector,
        version: contract.version, suggestion_id: @suggestion.id
      )
      contract.save!

      @suggestion.update!(status: "accepted", accepted_selector: @selector, accepted_at: Time.current)
      SelectorSuggestion.pending
                        .where(contract_id: contract.id, field_name: @suggestion.field_name, snapshot_id: @suggestion.snapshot_id)
                        .not.where(_id: @suggestion.id)
                        .update_all(status: "rejected")
      Result.success(contract)
    end

    private

    def apply(contract)
      if @suggestion.container?
        contract.container_selector = @selector
      else
        contract.field_spec(@suggestion.field_name).selector = @selector
      end
    end

    def valid_css?
      Nokogiri::HTML5.fragment("<p></p>").css(@selector)
      true
    rescue Nokogiri::CSS::SyntaxError, Nokogiri::XML::XPath::SyntaxError
      false
    end
  end
end
