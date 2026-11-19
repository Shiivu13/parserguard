class ApplicationJob < ActiveJob::Base
  # Mongo primary step-downs and network blips are transient.
  retry_on Mongo::Error::SocketError, Mongo::Error::NoServerAvailable, wait: :polynomially_longer, attempts: 5

  private

  # Jobs take string ids; a record deleted before the job runs is not an error.
  def find(model, id) = model.where(_id: BSON::ObjectId.from_string(id.to_s)).first
end
