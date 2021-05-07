require_relative "../../test_helper"

if GitHub.devtools_enabled?
  context "Routes for devtools/backscatter", GitHub::RoutingTest do
    test "GET Devtools::BackscatterController#index" do
      assert_routing(
        { :method => :get, :path => "/devtools/backscatter" },
        { :controller => "devtools/backscatter", :action => "index" }
      )
    end

    test "GET Devtools::BackscatterController#index tab" do
      assert_routing(
        { :method => :get, :path => "/devtools/backscatter/deprecation" },
        { :controller => "devtools/backscatter", :action => "index", :tab => "deprecation" }
      )
    end

    test "GET Devtools::BackscatterController#measurements" do
      assert_routing(
        { :method => :get, :path => "/devtools/backscatter/measurements" },
        { :controller => "devtools/backscatter", :action => "measurements" }
      )
    end

    test "DELETE Devtools::BackscatterController#destroy" do
      assert_routing(
        { :method => :delete, :path => "/devtools/backscatter" },
        { :controller => "devtools/backscatter", :action => "destroy" }
      )
    end
  end
end
