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
# Description: OCCI Infrastructure Compute
# Author(s): Hayati Bice, Florian Feldhaus, Piotr Kasprzak
##############################################################################

require 'occi/CategoryRegistry'
require 'occi/core/Action'
require 'occi/core/Kind'
require 'occi/core/Resource'
require 'occi/StateMachine'
require 'occi/ActionDelegator'

module OCCI
  module Infrastructure
    class Compute < OCCI::Core::Resource
      
      case $config["backend"]
      when 'opennebula'
        include OCCI::Backend::OpenNebula::Compute
      when 'dummy'
        include OCCI::Backend::Dummy::Compute
      end if $config

      # Define associated kind
      begin
        # Define actions
        restart_attributes = OCCI::Core::Attributes.new()
        restart_attributes << OCCI::Core::Attribute.new(name = 'graceful', mutable = false, mandatory = false, unique = true)
        restart_attributes << OCCI::Core::Attribute.new(name = 'warm', mutable = false, mandatory = false, unique = true)
        restart_attributes << OCCI::Core::Attribute.new(name = 'cold', mutable = false, mandatory = false, unique = true)
        
        ACTION_RESTART = OCCI::Core::Action.new(scheme = "http://schemas.ogf.org/occi/infrastructure/compute/action#", term = "restart",
        title = "Compute Action Restart",   attributes = restart_attributes)
                
        start_attributes = OCCI::Core::Attributes.new()
        
        ACTION_START   = OCCI::Core::Action.new(scheme = "http://schemas.ogf.org/occi/infrastructure/compute/action#", term = "start",
        title = "Compute Action Start",     attributes = start_attributes)
         
        stop_attributes = OCCI::Core::Attributes.new()
        stop_attributes << OCCI::Core::Attribute.new(name = 'graceful', mutable = false, mandatory = false, unique = true)
        stop_attributes << OCCI::Core::Attribute.new(name = 'acpioff', mutable = false, mandatory = false, unique = true)
        stop_attributes << OCCI::Core::Attribute.new(name = 'poweroff', mutable = false, mandatory = false, unique = true)
        
        ACTION_STOP    = OCCI::Core::Action.new(scheme = "http://schemas.ogf.org/occi/infrastructure/compute/action#", term = "stop",
        title = "Compute Action Stop",      attributes = stop_attributes)

        suspend_attributes = OCCI::Core::Attributes.new()
        suspend_attributes << OCCI::Core::Attribute.new(name = 'hibernate', mutable = false, mandatory = false, unique = true)
        suspend_attributes << OCCI::Core::Attribute.new(name = 'suspend', mutable = false, mandatory = false, unique = true)
          
        ACTION_SUSPEND = OCCI::Core::Action.new(scheme = "http://schemas.ogf.org/occi/infrastructure/compute/action#", term = "suspend",
        title = "Compute Action Suspend",   attributes = suspend_attributes)

        actions = [ACTION_RESTART, ACTION_START, ACTION_STOP, ACTION_SUSPEND]

        OCCI::CategoryRegistry.register(ACTION_START.category)
        OCCI::CategoryRegistry.register(ACTION_STOP.category)
        OCCI::CategoryRegistry.register(ACTION_SUSPEND.category)
        OCCI::CategoryRegistry.register(ACTION_RESTART.category)

        # Define state-machine
        STATE_INACTIVE  = OCCI::StateMachine::State.new("inactive")
        STATE_ACTIVE    = OCCI::StateMachine::State.new("active")
        STATE_SUSPENDED = OCCI::StateMachine::State.new("suspended")

        STATE_INACTIVE.add_transition(ACTION_START, STATE_ACTIVE)

        STATE_ACTIVE.add_transition(ACTION_STOP,    STATE_INACTIVE)
        STATE_ACTIVE.add_transition(ACTION_SUSPEND, STATE_SUSPENDED)
        # TODO: determine if the following modelling of the restart action is approriate
        STATE_ACTIVE.add_transition(ACTION_RESTART, STATE_ACTIVE)

        STATE_SUSPENDED.add_transition(ACTION_START, STATE_ACTIVE)

        related = [OCCI::Core::Resource::KIND]
        entity_type = self
        entities = []

        term    = "compute"
        scheme  = "http://schemas.ogf.org/occi/infrastructure#"
        title   = "Compute Resource"

        attributes = OCCI::Core::Attributes.new()
        attributes << OCCI::Core::Attribute.new(name = 'occi.compute.cores',        mutable = true,   mandatory = false,  unique = true)
        attributes << OCCI::Core::Attribute.new(name = 'occi.compute.architecture', mutable = true,   mandatory = false,  unique = true)
        attributes << OCCI::Core::Attribute.new(name = 'occi.compute.state',        mutable = false,  mandatory = true,   unique = true)
        attributes << OCCI::Core::Attribute.new(name = 'occi.compute.hostname',     mutable = true,   mandatory = false,  unique = true)
        attributes << OCCI::Core::Attribute.new(name = 'occi.compute.memory',       mutable = true,   mandatory = false,  unique = true)
        attributes << OCCI::Core::Attribute.new(name = 'occi.compute.speed',        mutable = true,   mandatory = false,  unique = true)

        KIND = OCCI::Core::Kind.new(actions, related, entity_type, entities, term, scheme, title, attributes)
        
        OCCI::CategoryRegistry.register(KIND)
        OCCI::Rendering::HTTP::LocationRegistry.register('/compute/', KIND)
      end

      def initialize(attributes, mixins = [])
        @state_machine  = OCCI::StateMachine.new(STATE_INACTIVE, [STATE_INACTIVE, STATE_ACTIVE, STATE_SUSPENDED], :on_transition => self.method(:update_state))
        # Initialize resource state
        attributes['occi.compute.state'] = state_machine.current_state.name

        # create action delegator
        delegator = OCCI::ActionDelegator.instance

        # register methods for compute actions
        delegator.register_method_for_action(OCCI::Infrastructure::Compute::ACTION_START, self, :start)
        delegator.register_method_for_action(OCCI::Infrastructure::Compute::ACTION_STOP,  self, :stop)
        delegator.register_method_for_action(OCCI::Infrastructure::Compute::ACTION_RESTART, self, :restart)
        delegator.register_method_for_action(OCCI::Infrastructure::Compute::ACTION_SUSPEND, self, :suspend)

        super(attributes, OCCI::Infrastructure::Compute::KIND ,mixins)
      end

    end
  end
end