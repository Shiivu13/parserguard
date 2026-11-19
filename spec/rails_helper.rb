require "spec_helper"
ENV["RAILS_ENV"] ||= "test"

if ENV["COVERAGE"] != "false"
  require "simplecov"
  SimpleCov.start "rails" do
    group "Services", "app/services"
    skip "/spec/"
  end
end

require_relative "../config/environment"
abort("The Rails environment is running in production mode!") if Rails.env.production?
require "rspec/rails"
require "webmock/rspec"

Rails.root.glob("spec/support/**/*.rb").sort.each { |f| require f }

WebMock.disable_net_connect!(allow_localhost: true)

RSpec.configure do |config|
  config.use_active_record = false
  config.filter_rails_from_backtrace!
  config.include FactoryBot::Syntax::Methods
  config.include ActiveJob::TestHelper

  config.before(:suite) { Mongoid::Tasks::Database.create_indexes }
  config.before(:each) { Mongoid.truncate! }
end
