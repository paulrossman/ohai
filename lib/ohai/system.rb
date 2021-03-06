#
# Author:: Adam Jacob (<adam@opscode.com>)
# Copyright:: Copyright (c) 2008 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'ohai/loader'
require 'ohai/log'
require 'ohai/mash'
require 'ohai/runner'
require 'ohai/dsl'
require 'ohai/mixin/from_file'
require 'ohai/mixin/command'
require 'ohai/mixin/os'
require 'ohai/mixin/string'
require 'ohai/provides_map'
require 'ohai/hints'
require 'mixlib/shellout'

require 'yajl'

module Ohai

  class System
    attr_accessor :data
    attr_reader :provides_map
    attr_reader :v6_dependency_solver

    def initialize
      @data = Mash.new
      @provides_map = ProvidesMap.new

      @v6_dependency_solver = Hash.new
      @plugin_path = ""

      @loader = Ohai::Loader.new(self)
      @runner = Ohai::Runner.new(self, true)

      Ohai::Hints.refresh_hints()
    end

    def [](key)
      @data[key]
    end

    def all_plugins(attribute_filter=nil)
      load_plugins
      run_plugins(true, false, attribute_filter)
    end

    def load_plugins
      Ohai::Config[:plugin_path].each do |path|
        Dir[File.join(path, '**', '*.rb')].each do |plugin_file_path|
          # Load all the *.rb files under the configured paths in :plugin_path
          plugin = @loader.load_plugin(plugin_file_path)

          if plugin && plugin.version == :version6
            # Capture the plugin in @v6_dependency_solver if it is a V6 plugin
            # to be able to resolve V6 dependencies later on.
            # We are using the partial path in the dep solver as a key.
            partial_path = Pathname.new(plugin_file_path).relative_path_from(Pathname.new(path)).to_s

            unless @v6_dependency_solver.has_key?(partial_path)
              @v6_dependency_solver[partial_path] = plugin
            else
              Ohai::Log.debug("Plugin '#{plugin_file_path}' is already loaded.")
            end
          end
        end
      end
    end

    def run_plugins(safe = false, force = false, attribute_filter = nil)
      # First run all the version 6 plugins
      @v6_dependency_solver.values.each do |v6plugin|
        @runner.run_plugin(v6plugin, force)
      end

      # Then run all the version 7 plugins
      begin
        @provides_map.all_plugins(attribute_filter).each { |plugin|
          @runner.run_plugin(plugin, force)
        }
      rescue Ohai::Exceptions::AttributeNotFound, Ohai::Exceptions::DependencyCycle => e
        Ohai::Log.error("Encountered error while running plugins: #{e.inspect}")
        raise
      end
    end

    def pathify_v6_plugin(plugin_name)
      path_components = plugin_name.split("::")
      File.join(path_components) + ".rb"
    end

    #
    # Below APIs are from V6.
    # Make sure that you are not breaking backwards compatibility
    # if you are changing any of the APIs below.
    #
    def require_plugin(plugin_ref, force=false)
      plugins = [ ]
      # This method is only callable by version 6 plugins.
      # First we check if there exists a v6 plugin that fulfills the dependency.
      if @v6_dependency_solver.has_key? pathify_v6_plugin(plugin_ref)
        # Note that: partial_path looks like Plugin::Name
        # keys for @v6_dependency_solver are in form 'plugin/name.rb'
        plugins << @v6_dependency_solver[pathify_v6_plugin(plugin_ref)]
      else
        # While looking up V7 plugins we need to convert the plugin_ref to an attribute.
        attribute = plugin_ref.gsub("::", "/")
        begin
          plugins = @provides_map.find_providers_for([attribute])
        rescue Ohai::Exceptions::AttributeNotFound
          Ohai::Log.debug("Can not find any v7 plugin that provides #{attribute}")
          plugins = [ ]
        end
      end

      if plugins.empty?
        raise Ohai::Exceptions::DependencyNotFound, "Can not find a plugin for dependency #{plugin_ref}"
      else
        plugins.each do |plugin|
          begin
            @runner.run_plugin(plugin, force)
          rescue SystemExit, Interrupt
            raise
          rescue Ohai::Exceptions::DependencyCycle, Ohai::Exceptions::AttributeNotFound => e
            Ohai::Log.error("Encountered error while running plugins: #{e.inspect}")
            raise
          rescue Exception,Errno::ENOENT => e
            Ohai::Log.debug("Plugin #{plugin.name} threw exception #{e.inspect} #{e.backtrace.join("\n")}")
          end
        end
      end
    end

    # TODO: fix for running w/new internals
    # add updated function to v7?
    def refresh_plugins(path = '/')
      Ohai::Hints.refresh_hints()

      parts = path.split('/')
      if parts.length == 0
        h = @metadata
      else
        parts.shift if parts[0].length == 0
        h = @metadata
        parts.each do |part|
          break unless h.has_key?(part)
          h = h[part]
        end
      end

      refreshments = collect_plugins(h)
      Ohai::Log.debug("Refreshing plugins: #{refreshments.join(", ")}")

      refreshments.each do |r|
        @seen_plugins.delete(r) if @seen_plugins.has_key?(r)
      end
      refreshments.each do |r|
        require_plugin(r) unless @seen_plugins.has_key?(r)
      end
    end

    #
    # Serialize this object as a hash
    #
    def to_json
      Yajl::Encoder.new.encode(@data)
    end

    #
    # Pretty Print this object as JSON
    #
    def json_pretty_print(item=nil)
      Yajl::Encoder.new(:pretty => true).encode(item || @data)
    end

    def attributes_print(a)
      data = @data
      a.split("/").each do |part|
        data = data[part]
      end
      raise ArgumentError, "I cannot find an attribute named #{a}!" if data.nil?
      case data
      when Hash,Mash,Array,Fixnum
        json_pretty_print(data)
      when String
        if data.respond_to?(:lines)
          json_pretty_print(data.lines.to_a)
        else
          json_pretty_print(data.to_a)
        end
      else
        raise ArgumentError, "I can only generate JSON for Hashes, Mashes, Arrays and Strings. You fed me a #{data.class}!"
      end
    end

  end
end
