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

  config.before(:suite) do
    # create_indexes only sees loaded models; test env does not eager load.
    Rails.autoloaders.main.eager_load_dir(Rails.root.join("app/models"))
    Mongoid::Tasks::Database.create_indexes
  end
  config.after(:suite) { Mongoid.default_client.database.drop unless ENV["MONGODB_TEST_URI"] }
  config.before(:each) do
    Mongoid.truncate!
    clear_enqueued_jobs
    clear_performed_jobs
  end
end
