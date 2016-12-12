# Encoding: utf-8
# Cloud Foundry Java Buildpack
# Copyright 2013-2017 the original author or authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'fileutils'
require 'java_buildpack/component/versioned_dependency_component'
require 'java_buildpack/jre'
require 'java_buildpack/util/shell'
require 'java_buildpack/util/qualify_path'
require 'open3'
require 'tmpdir'
require 'zip'

module JavaBuildpack
  module Jre

    # Encapsulates the detect, compile, and release functionality for the OpenJDK-like memory calculator
    class OpenJDKLikeMemoryCalculator < JavaBuildpack::Component::VersionedDependencyComponent
      include JavaBuildpack::Util

      # (see JavaBuildpack::Component::BaseComponent#compile)
      def compile
        download(@version, @uri) do |file|
          FileUtils.mkdir_p memory_calculator.parent
          if @version[0] < '2'
            unpack_calculator file
          else
            unpack_compressed_calculator file
          end
          memory_calculator.chmod 0o755
        end

        show_settings memory_calculation_string(Pathname.new(Dir.pwd))
      end

      # Returns a fully qualified memory calculation command to be prepended to the buildpack's command sequence
      #
      # @return [String] the memory calculation command
      def memory_calculation_command
        "CALCULATED_MEMORY=$(#{memory_calculation_string(@droplet.root)})"
      end

      # (see JavaBuildpack::Component::BaseComponent#release)
      def release
        @droplet.java_opts.add_preformatted_options '$CALCULATED_MEMORY'
      end

      protected

      # (see JavaBuildpack::Component::VersionedDependencyComponent#supports?)
      def supports?
        true
      end

      private

      def memory_calculator
        @droplet.sandbox + "bin/java-buildpack-memory-calculator-#{@version}"
      end

      def memory_calculator_tar
        platform = `uname -s` =~ /Darwin/ ? 'darwin' : 'linux'
        @droplet.sandbox + "bin/java-buildpack-memory-calculator-#{platform}"
      end

      def memory_calculation_string(relative_path)
        "#{qualify_path memory_calculator, relative_path} " \
              '-totMemory=$MEMORY_LIMIT ' \
              "-stackThreads=#{stack_threads @configuration} " \
              "-loadedClasses=#{app_class_files_count @configuration}" \
              "#{vm_options @configuration}"
      end

      def app_class_files_count(configuration)
        configuration['class_count'] ? configuration['class_count'] : count_dir_classes(@application.root, 0)
      end

      def count_dir_classes(application_root, count)
        application_root.each_child do |child|
          count += 1 if child.basename.to_s.end_with?('.class', '.groovy')
          count = count_dir_classes(child, count) if child.directory?
          next unless child.basename.to_s.end_with?('.war', '.jar')
          count = count_archive(child, count)
        end
        count
      end

      def count_archive(file, count)
        Zip::File.open(file) do |zip_file|
          zip_file.each do |entry|
            count += 1 if entry.name.end_with?('.class', '.groovy')
            next unless entry.name.end_with?('.war', '.jar')
            Dir.mktmpdir do |dir|
              entry.extract("#{dir}/archive")
              count = count_archive("#{dir}/archive", count)
            end
          end
        end
        count
      end

      def unpack_calculator(file)
        FileUtils.cp_r(file.path, memory_calculator)
      end

      def unpack_compressed_calculator(file)
        shell "tar xzf #{file.path} -C #{memory_calculator.parent} 2>&1"
        FileUtils.mv(memory_calculator_tar, memory_calculator)
      end

      def stack_threads(configuration)
        configuration['stack_threads']
      end

      def vm_options(configuration)
        return '' unless configuration['vm_options']
        options = configuration['vm_options'].map { |k, v| "-#{k}#{v}" }.join(' ')
        " -vmOptions=\"#{options}\""
      end

      def show_settings(*args)
        Open3.popen3(*args) do |_stdin, stdout, stderr, wait_thr|
          status         = wait_thr.value
          stderr_content = stderr.gets nil
          stdout_content = stdout.gets nil
          puts "       #{stderr_content}" if stderr_content
          raise unless status.success?
          puts "       Memory Settings: #{stdout_content}"
        end
      end

    end

  end
end
