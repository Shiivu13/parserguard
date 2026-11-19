require "rails_helper"

RSpec.describe "Environment smoke" do
  it "boots Rails" do
    expect(Rails.application).to be_present
  end

  it "reaches MongoDB" do
    result = Mongoid.default_client.database.command(ping: 1)
    expect(result.documents.first["ok"]).to eq(1.0)
  end
end
