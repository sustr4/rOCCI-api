##############################################################################
#  Copyright 2011 Service Computing group, TU Dortmund
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
##############################################################################

##############################################################################
# Description: OCCI RESTful Web Service
# Author(s): Hayati Bice, Florian Feldhaus, Piotr Kasprzak
##############################################################################

##############################################################################
# Require Ruby Gems

# gems
require 'rubygems'
require 'sinatra'
require 'logger'

# Ruby standard library
require 'uri'
require 'fileutils'

# Server configuration
require 'occi/Configuration'

##############################################################################
# Initialize logger

$stdout.sync = true
$log = Logger.new(STDOUT)

##############################################################################
# Read configuration file and set loglevel

CONFIGURATION_FILE = 'etc/occi-server.conf'

## initialize temporary image path
$image_path = ""

$config = OCCI::Configuration.new(CONFIGURATION_FILE)

if $config['LOG_LEVEL'] != nil
  $log.level = case $config['LOG_LEVEL'].upcase
  when 'FATAL' then Logger::FATAL
  when 'ERROR' then Logger::ERROR
  when 'WARN' then Logger::WARN
  when 'INFO' then Logger::INFO
  when 'DEBUG' then Logger::DEBUG
  else
    $log.warn("Invalid loglevel specified. Loglevel set to INFO")
    Logger::INFO
  end
end

##############################################################################
# initialize backend, currently only Dummy and OpenNebula are supported

begin
  $backend = case $config["backend"]
  when "opennebula"
    require 'occi/backend/OpenNebula'
    OCCI::Backend::OpenNebula.new($config['OPENNEBULA_CONFIG'])
  when "dummy" then
    require 'occi/backend/Dummy'
    OCCI::Backend::Dummy.new()
  else raise "Backend '" + $config["backend"] + "' not found"
  end
rescue RuntimeError => e
  $log.fatal "#{e}: #{e.backtrace}"
  exit 1
end

##############################################################################
# Require OCCI classes

# Exceptions
require 'occi/Exceptions'

# Category registry
require 'occi/CategoryRegistry'

# OCCI Core classes
require 'occi/core/Action'
require 'occi/core/Category'
require 'occi/core/Entity'
require 'occi/core/Kind'
require 'occi/core/Link'
require 'occi/core/Mixin'
require 'occi/core/Resource'

# OCCI Infrastructure classes
require 'occi/infrastructure/Compute'
require 'occi/infrastructure/Storage'
require 'occi/infrastructure/Network'
require 'occi/infrastructure/Networkinterface'
require 'occi/infrastructure/StorageLink'
require 'occi/infrastructure/Ipnetworking'
require 'occi/mixins/Reservation'

# OCCI HTTP rendering
require 'occi/rendering/http/Renderer'
require 'occi/rendering/http/LocationRegistry'
require 'occi/rendering/http/OCCIParser'
require 'occi/rendering/http/OCCIRequest'

##############################################################################
# Configuration of HTTP Authentication

if $config['username'] != nil and $config['password'] != nil
  use Rack::Auth::Basic, "Restricted Area" do |username, password|
    [username, password] == [$config['username'], $config['password']]
  end
end

##############################################################################
# Sinatra methods for handling HTTP requests

begin
  ############################################################################
  # GET request

  get '/web/' do
    begin
      if $config[:webinterface] == 'enabled'
        require 'erb'
        rhtml = ERB.new(File.read('etc/html/template.erb')).result(binding)
        response.write(rhtml)
        break
      end
    end
  end

  get '*' do
    begin
      # render general OCCI response
      tmp = OCCI::Rendering::HTTP::Renderer.render_response(response,request)
      response = tmp

      occi_request = OCCI::Rendering::HTTP::OCCIRequest.new(request,params)

      location = request.path_info
      $log.debug("Requested location: #{location}")

      # Query interface: return all supported kinds + mixins
      if location == "/-/"
        $log.info("Listing all kinds and mixins ...")
        response = OCCI::Rendering::HTTP::Renderer.render_category_type(occi_request.categories,response)
        response.status = HTTP_STATUS_CODE["OK"]
        break
      end

      object = OCCI::Rendering::HTTP::LocationRegistry.get_object_by_location(location)

      # Render exact matches referring to kinds / mixins
      if object != nil && object.kind_of?(OCCI::Core::Category)
        raise "Only mixins / kinds are supported for exact match rendering: location: #{location}; object: #{object}" if !object.instance_variable_defined?(:@entities)
        $log.info("Listing all entities for kind/mixin [#{object.type_identifier}] ...")
        locations = []
        object.entities.each do |entity|
          locations << OCCI::Rendering::HTTP::LocationRegistry.get_location_of_object(entity)
        end
        response = OCCI::Rendering::HTTP::Renderer.render_locations(locations,response)
        response.status = HTTP_STATUS_CODE["OK"]
        break
      end

      # Render exact matches referring to resources
      if object != nil && object.kind_of?(OCCI::Core::Resource)
        $log.info("Rendering resource [#{object.type_identifier}] for location [#{location}] ...")
        object.refresh
        response = OCCI::Rendering::HTTP::Renderer.render_resource(object,response)
        break
      end

      # Render locations ending with "/", which are not exact matches
      if location.end_with?("/")
        $log.info("Listing all resource instances below location: #{location}")
        resources = OCCI::Rendering::HTTP::LocationRegistry.get_resources_below_location(location, occi_request.categories)
        locations = []
        resources.each do |resource|
          resource.refresh if resource.kind_of?(OCCI::Core::Resource)
          locations << OCCI::Rendering::HTTP::LocationRegistry.get_location_of_object(resource)
        end
        response_header = OCCI::Rendering::HTTP::Renderer.render_locations(locations,response)
        break
      end

      # Invalid request url
      raise "Invalid request url: #{location}"

      # This must be the last statement in this block, so that sinatra does not try to respond with random body content
      # (or fail utterly while trying to do that!)
      nil

    rescue Exception => e

      $log.error(e)
      response.status = HTTP_STATUS_CODE["Bad Request"]

    end
  end

  ############################################################################
  # POST request

  # Create an instance appropriate to category field and optinally link an instance to another one
  post '*' do
    begin
      # render general OCCI response
      
      tmp = OCCI::Rendering::HTTP::Renderer.render_response(response,request)
      response = tmp

      occi_request = OCCI::Rendering::HTTP::OCCIRequest.new(request,params)

      location = request.path_info
      $log.debug("Requested location: #{location}")

      # Trigger action on resources(s)
      unless occi_request.action.nil?
        $log.info("Triggering action on resource(s)...")
        resources = OCCI::Rendering::HTTP::LocationRegistry.get_resources_below_location(location)
        $log.debug(occi_request.attributes)
        method    = request.env["HTTP_X_OCCI_ATTRIBUTE"]

        raise "No entities corresponding to location [#{location}] could be found!" if entities == nil

        $log.debug("Action [#{action}] to be triggered on [#{entities.length}] entities:")
        delegator = OCCI::ActionDelegator.instance
        resources.each do |resource|
          resource.refresh if resource.kind_of?(OCCI::Core::Resource)
          delegator.delegate_action(action, method, resource)
        end
        break;
      end

      # If kind is a link and no actions specified then create link
      unless occi_request.links.empty?
        $log.info("Creating link...")

        target_uri = URI.parse(occi_request.attributes["occi.core.target"])
        target = OCCI::Rendering::HTTP::LocationRegistry.get_object_by_location(target_uri.path)

        source_uri = URI.parse(occi_request.attributes["occi.core.source"])
        source = OCCI::Rendering::HTTP::LocationRegistry.get_object_by_location(source_uri.path)

        link = kind.entity_type.new(attributes)
        source.links << link
        target.links << link

        link_location = link.get_location()
        OCCI::Rendering::HTTP::LocationRegistry.register_location(link_location, link)
        response['Location'] = OCCI::Rendering::HTTP::LocationRegistry.get_absolute_location_of_object(link,request.host_with_port)
        break
      end

      # If kind is not link and no actions specified, then create resource
      $log.info("Creating resource...")

      # Create resource
      unless occi_request.kind.nil?
        $log.debug(occi_request.mixins)
        resource = occi_request.kind.entity_type.new(occi_request.attributes, occi_request.mixins)

        occi_request.links.each do |link|
          $log.debug(link)
          target = OCCI::Rendering::HTTP::LocationRegistry.get_object_by_location(link.target)
          raise "Link target not found!" if target == nil

          link.attributes["occi.core.target"] = link.target
          link.attributes["occi.core.source"] = resource.get_location

          link = kind.entity_type.new(link.attributes)

          resource.links << link
          target.links << link

          OCCI::Rendering::HTTP::LocationRegistry.register_location(link.get_location, link)
        end

        resource.deploy()

        $log.debug('Location:' + resource.get_location)

        OCCI::Rendering::HTTP::LocationRegistry.register(resource.get_location, resource)

        OCCI::Rendering::HTTP::Renderer.render_location(OCCI::Rendering::HTTP::LocationRegistry.get_absolute_location_of_object(resource),response)
      end

      # This must be the last statement in this block, so that sinatra does not try to respond with random body content
      # (or fail utterly while trying to do that!)
      nil

    rescue Exception => e

      $log.error(e)
      response.status  = HTTP_STATUS_CODE["Bad Request"]

    end
  end

  ############################################################################
  # PUT request

  put '*' do
    begin
      # render general OCCI response
      tmp = OCCI::Rendering::HTTP::Renderer.render_response(response,request)
      response = tmp

      occi_request = OCCI::Rendering::HTTP::OCCIRequest.new(request,params)

      location = request.path_info
      $log.debug("Requested location: #{location}")

      # Create user defined mixin
      if location == "/-/"
        $log.info("Creating user defined mixin...")

        mixin   = $categoryRegistry.get_categories_by_category_string(request.env['HTTP_CATEGORY'], filter="mixins")[0]

        raise OCCI::MixinAlreadyExistsError, "Mixin [#{mixin}] already exists!" unless mixin == nil

        mixin_category_data = OCCI::Parser.new(request.env['HTTP_CATEGORY']).category_value
        $log.debug("Category data for mixin: #{mixin_category_data}")

        raise "Mandatory information missing (term | scheme | location)!" unless mixin_category_data.term != nil && mixin_category_data.scheme != nil && mixin_category_data.location != nil
        raise "Category class must be set to 'mixin'!"                    unless mixin_category_data.clazz == "mixin"

        raise "Location #{mixin_category_data.location} already used for another object: " +
        $locationRegistry.get_object_by_location(mixin_category_data.location) unless $locationRegistry.get_object_by_location(mixin_category_data.location) == nil

        related_mixin = $categoryRegistry.get_categories_by_category_string(related, filter="mixins")[0] if mixin_category_data.related != nil
        mixin = OCCI::Core::Mixin.new(mixin_category_data.term, mixin_category_data.scheme, mixin_category_data.title, nil, [], related_mixin, [])
        $categoryRegistry.register_mixin(mixin)
        $locationRegistry.register_location(mixin_category_data.location, mixin)
        break
      end

      # Add an resource instance to a mixin
      unless occi_request.mixin.empty?
        mixin = $locationRegistry.get_object_by_location(location)

        OCCI::Parser.new(request.env["HTTP_X_OCCI_LOCATION"]).location_values.each do |entity_location|

          entity_uri = URI.parse(entity_location)
          entity = $locationRegistry.get_object_by_location(entity_uri.path)

          raise "No entity found at location: #{entity_location}"                                       if entity == nil
          raise "Object referenced by uri [#{entity_location}] is not a OCCI::Core::Resource instance!" if !entity.kind_of?(OCCI::Core::Resource)

          $log.debug("Associating entity [#{entity}] at location #{entity_location} with mixin #{mixin}")

          entity.mixins << mixin
        end
        break
      end

      # Update resource instance(s) at the given location
      if OCCI::Rendering::HTTP::LocationRegistry.get_object_by_location(location) != nil
        resource.refresh if resource.kind_of?(OCCI::Core::Resource)
        # Determine set of resources to be updated
        if $locationRegistry.get_object_by_location(location).kind_of?(OCCI::Core::Resource)
          entities = [$locationRegistry.get_object_by_location(location)]
        else
          entities = $locationRegistry.get_resources_below_location(location)
        end
        $log.info("Updating [#{entities.size}] entities...")

        # Update / add mixins
        if request.env['HTTP_CATEGORY'] != nil
          mixins = $categoryRegistry.get_categories_by_category_string(request.env['HTTP_CATEGORY'], filter="mixins")
          entities.each do |entity|
            entity.mixins = mixins
          end
        end

        # Update / add attributes
        if request.env['HTTP_X_OCCI_ATTRIBUTE'] != nil
          attributes = OCCI::Parser.new(request.env["HTTP_X_OCCI_ATTRIBUTE"]).attributes_attr
          entities.each do |entity|
            entity.attributes.merge!(attributes)
          end
        end

        # Update / add links
        if request.env['HTTP_LINK'] != nil

          links = OCCI::Parser.new(request.env['HTTP_LINK']).link_values

          links.each do |link_data|
            $log.debug("Extracted link data: #{link_data}")
            raise "Mandatory information missing (related | target | category)!" unless link_data.related != nil && link_data.target != nil && link_data.category != nil

            kind = $categoryRegistry.get_categories_by_category_string(link_data.category, filter="kinds")[0]
            raise "No kind for category string: #{link_data.category}" unless kind != nil

            entities.each do |entity|

              target          = $locationRegistry.get_object_by_location(target_location)
              source_location = $locationRegistry.get_location_of_object(entity)

              attributes = link_data.attributes.clone
              attributes["occi.core.target"] = target_location
              attributes["occi.core.source"] = source_location

              link = kind.entity_type.new(attributes)
              $locationRegistry.register_location(link.get_location(), link)

              target.links << link
              entity.links << link
            end
          end
        end
        break
      end

      # Create resource instance at the given location
      raise "Creating resources with method 'put' is currently not possible!"

      # This must be the last statement in this block, so that sinatra does not try to respond with random body content
      # (or fail utterly while trying to do that!)
      nil

    rescue OCCI::MixinAlreadyExistsError => e

      $log.error(e)
      response.status  = HTTP_STATUS_CODE["Conflict"]

    rescue Exception => e

      $log.error(e)
      response.status = HTTP_STATUS_CODE["Bad Request"]

    end
  end

  ############################################################################
  # DELETE request

  delete '*' do
    begin
      tmp = OCCI::Rendering::HTTP::Renderer.render_response(response,request)
      response = tmp

      occi_request = OCCI::Rendering::HTTP::OCCIRequest.new(request,params)

      location = request.path_info
      $log.debug("Requested location: #{location}")

      # Location references query interface => delete provided mixin
      if location == "/-/"
        $log.info("Deleting mixin #{occi_request.mixin.type_identifier}")
        OCCI::Rendering::HTTP::LocationRegistry.unregister(mixin.get_location)
        OCCI::CategoryRegistry.unregister(mixin)
        break
      end

      # Location references a mixin => unassociate all provided resources (by X_OCCI_LOCATION) from it
      object = OCCI::Rendering::HTTP::LocationRegistry.get_object_by_location(location)
      if object != nil && object.kind_of?(OCCI::Core::Mixin)
        object = OCCI::Rendering::HTTP::LocationRegistry.get_object_by_location(location)
        $log.info("Unassociating entities from mixin: #{object}")

        occi_request.locations.each do |location|
          entity = OCCI::Rendering::HTTP::LocationRegistry.get_object_by_location(location)
          mixin.entities.delete(entity)
        end
        break
      end

      # Determine set of resources to be deleted
      object = OCCI::Rendering::HTTP::LocationRegistry.get_object_by_location(location)

      if object.kind_of? OCCI::Core::Entity
        entities = [OCCI::Rendering::HTTP::LocationRegistry.get_object_by_location(location)]
      else
        entities = OCCI::Rendering::HTTP::LocationRegistry.get_resources_below_location(location)
      end

      entities.each do |entity|
        location = entity.get_location
        entity.delete()
        OCCI::Rendering::HTTP::LocationRegistry.unregister(location)
      end

      # This must be the last statement in this block, so that sinatra does not try to respond with random body content
      # (or fail utterly while trying to do that!)
      nil

    rescue Exception => e

      $log.error(e)
      response.status = HTTP_STATUS_CODE["Bad Request"]
    end
  end
end