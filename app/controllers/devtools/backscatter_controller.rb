class Devtools::BackscatterController < DevtoolsController
  areas_of_responsibility :stafftools

  def index
    @since        = graphite_time_range
    @called       = GitHub::Backscatter.results

    @measures     = GitHub::Backscatter.measures
    @traces       = GitHub::Backscatter.traces
    @deprecations = GitHub::Backscatter.deprecations
  rescue GitHub::Backscatter::Storage::OperationFailed,
      Faraday::Error::ConnectionFailed,
      Faraday::Error::TimeoutError => boom
    @called = @measurements = []
    flash.now[:error] = "Could not retrieve backscatter results: #{boom.message}"
  end

  def measurements
    since        = graphite_time_range
    measurements = GitHub::Backscatter.recent_measurements(since)

    respond_to do |format|
      format.html do
        render :partial => "devtools/backscatter/measurements",
          :locals => { :since => since, :measurements => measurements }
      end
    end
  end

  def destroy
    GitHub::Backscatter::Storage.delete_called_method(params[:signature])
  rescue GitHub::Backscatter::Storage::OperationFailed => boom
    flash[:error] = "Could not clear backscatter data: #{boom.message}"
  ensure
    redirect_to backscatter_path
  end

  def disable
    GitHub::Backscatter.disable
    flash[:notice] = "Backscatter disabled, good luck."
    redirect_to backscatter_path
  end

  def enable
    GitHub::Backscatter.enable
    flash[:notice] = "Backscatter enabled, have fun!"
    redirect_to backscatter_path
  end

  private

  def graphite_time_range
    return params[:since] if params[:since] && params[:since] =~ /\A-\d+([a-z]+)\z/i
    '-1day'
  end
end
