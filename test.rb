require 'octokit'
require 'json'
require 'open3'
require 'pathname'
require 'active_support/core_ext/hash'
require 'find'
require 'logger'

class CodeMessage
  def initialize(filename, linenumber, colnumber, messagetype, message)
    @filename = filename
    @linenumber = linenumber
    @colnumber = colnumber
    @messagetype = messagetype
    @message = message
  end

  def filename
    @filename
  end

  def linenumber
    @linenumber
  end
  
  def colnumber
    @colnumber
  end

  def messagetype
    @messagetype
  end

  def is_warning
    @messagetype =~ /.*warn.*/i
  end

  def is_error
    @messagetype =~ /.*err.*/i
  end

  def message
    @message
  end

  def inspect
    hash = {}
    instance_variables.each {|var| hash[var.to_s.delete("@")] = instance_variable_get(var) }
    return hash
  end

end

class TestResult
  def initialize(name, status, time)
    @name = name
    @status = status
    @time = time
  end

  def passed
    return @status == "passed"
  end

  def inspect
    hash = {}
    instance_variables.each {|var| hash[var.to_s.delete("@")] = instance_variable_get(var) }
    return hash
  end

end

class Configuration
  def initialize(token, results_repository, results_path, repository, compiler, compiler_version, architecture, os, os_distribution)
    @token = token
    @results_repository = results_repository
    @results_path = results_path
    @repository = repository
    @compiler = compiler
    @compiler_version = compiler_version
    @architecture = architecture
    @os = os
    @os_distribution = os_distribution
  end

  def token
    @token
  end

  def results_repository
    @results_repository
  end

  def results_path
    @results_path
  end


  def repository
    @repository
  end

  def repository_name=(name)
    @repository_name = name
  end

  def repository_name
    @repository_name
  end

  def compiler
    @compiler
  end

  def compiler_version
    @compiler_version
  end

  def architecture
    @architecture
  end

  def os
    @os
  end

  def os_distribution
    @os_distribution
  end

end

class PotentialBuild

  def initialize(client, config, repository, tag_name, commit_sha, branch_name, release_url, release_assets, 
                 pull_id, pull_request_base_repository, pull_request_base_ref)
    @config = config
    @repository = repository
    @tag_name = tag_name
    @commit_sha = commit_sha
    @branch_name = branch_name
    @release_url = release_url
    @release_assets = release_assets
    @needs_run = true
    @client = client

    @buildid = @tag_name ? @tag_name : @commit_sha
    @refspec = @tag_name ? @tag_name : @branch_name

    @pull_id = pull_id
    @pull_request_base_repository = pull_request_base_repository
    @pull_request_base_ref = pull_request_base_ref


    @buildid = "#{@buildid}-PR#{@pull_id}" if !@pull_id.nil?

    @logger = Logger.new(STDOUT)
    @package_location = nil
    @test_results = nil
    @build_results = nil

  end

  def is_release
    return !@release_url.nil?
  end

  def is_pull_request
    return !@pull_id.nil?
  end

  def pull_request_issue_id
    return @pull_id
  end

  def runScript(commands)
    allout = ""
    allerr = "" 
    allresult = 0

    commands.each { |cmd|
      stdout, stderr, result = Open3.capture3(cmd)

      stdout.split("\n").each { |l| 
        @logger.debug("cmd: #{cmd}: stdout: #{l}")
      }

      stderr.split("\n").each { |l| 
        @logger.info("cmd: #{cmd}: stderr: #{l}")
      }

      if cmd != commands.last && result != 0
        @logger.error("Error running script command: #{stderr}")
        raise stderr
      end

      allout += stdout
      allerr += stderr
      allresult += result.exitstatus
    }

    return allout, allerr, allresult
  end

  def device_id
    "#{@config.architecture}-#{@config.os}-#{@config.os_distribution}-#{@config.compiler}-#{@config.compiler_version}"
  end

  def build_base_name
    "#{@config.repository_name}-#{@buildid}-#{device_id}"
  end

  def results_file_name
    "#{build_base_name}-results.html"
  end

  def short_build_base_name
    "#{@config.repository_name}-#{@config.architecture}-#{@config.os}-#{@buildid}"
  end


  def package_name
    "#{short_build_base_name()}"
  end

  def package_extension
    "deb"
  end

  def package_full_name
    "#{short_build_base_name}.#{package_extension}"
  end

  def relative_path(p)
    return Pathname.new(p).realpath.relative_path_from(Pathname.new(build_base_name).realdirpath)
  end

  def process_gcc_results(stdout, stderr, result)
    results = []

    stderr.split("\n").each { |err|
      /(?<filename>\S+):(?<linenumber>[0-9]+):(?<colnumber>[0-9]+): (?<messagetype>\S+): (?<message>.*)/ =~ err

      if !filename.nil? && !messagetype.nil? && messagetype != "info"
        results << CodeMessage.new(relative_path(filename), linenumber, colnumber, messagetype, message)
      end
    }

    @build_results = results

    return result == 0
  end

  def checkout(src_dir)
    out, err, result = runScript(
      ["mkdir #{src_dir}",
       "cd #{src_dir} && git init",
       "cd #{src_dir} && git pull https://#{@config.token}@github.com/#{@repository} #{@refspec}" ])

    if !@commit_sha.nil? && @commit_sha != "" && result == 0
      out, err, result = runScript( ["cd #{src_dir} && git checkout #{@commit_sha}"] );
    end

    return result == 0

  end

  def build(src_dir, build_dir, build_type)
    out, err, result = runScript(
      ["mkdir -p #{build_dir}",
       "cd #{build_dir} && cmake ../ -DCPACK_PACKAGE_FILE_NAME:STRING=#{package_name} -DCMAKE_BUILD_TYPE:STRING=#{build_type}",
       "cd #{build_dir} && make -j3"])

    return process_gcc_results(out,err,result)
  end

  def package(build_dir)
    pack_stdout, pack_stderr, pack_result = runScript(
      ["cd #{build_dir} && cpack -G DEB "])

    if pack_result != 0
      raise "Error building package: #{pack_stderr}"
    end

    return "#{build_dir}/#{package_full_name}"
  end

  def do_package
    if is_release && @needs_run
      src_dir = "#{build_base_name}-release"
      build_dir = "#{src_dir}/build"

      checkout src_dir
      build src_dir, build_dir, "Release"

      begin 
        @package_location = package build_dir
        puts "Package successfully built at: #{@package_location}"
      rescue => e
        @logger.error("Error creating package #{e}")
      end

    end
  end

  def process_ctest_results build_dir, stdout, stderr, result
    Find.find(build_dir) do |path|
      if path =~ /.*Test.xml/
        results = []

        xml = Hash.from_xml(File.open(path).read)
        testresults = xml["Site"]["Testing"]
        testresults.each { |t, n|
          puts "key: #{t} value: #{n}"
          if t == "Test"
            puts "key: #{t}"
            r = n["Results"]
            puts "Results: #{r}"
            if r
              nm = r["NamedMeasurement"]
              puts nm

              if !nm.nil?
                nm.each { |measurement|
                  puts measurement
                  if measurement["name"] == "Execution Time"
                    puts "MADE IT"
                    results << TestResult.new(n["Name"], n["Status"], measurement["Value"]);
                  end
                }
              end
            end
          end
        }

        return results
      end

    end
  end

  def filter_build files
    files.each{ |f|
      @needs_run = false if f.end_with? results_file_name
    }
  end

  def test build_dir
    test_stdout, test_stderr, test_result = runScript(["cd #{build_dir} && ctest -D ExperimentalTest"]);
    @test_results = process_ctest_results build_dir, test_stdout, test_stderr, test_result
  end

  def do_test
    if @needs_run
      src_dir = build_base_name
      build_dir = "#{build_base_name}/build"

      checkout_succeeded  = checkout src_dir
      build_succeeded = build src_dir, build_dir, "Debug" if checkout_succeeded
      test build_dir if build_succeeded 
    end
  end 



  def inspect
    hash = {}
    instance_variables.each {|var| hash[var.to_s.delete("@")] = instance_variable_get(var) }
    return hash
  end

  def post_results
    dateprefix = DateTime.now.utc.strftime("%F")

    test_results_data = []

    test_results_passed = 0
    test_results_total = 0

    if !@test_results.nil?
      @test_results.each { |t| 
        test_results_total += 1
        test_results_passed += 1 if t.passed

        test_results_data << t.inspect;
      }
    end

    build_errors = 0
    build_warnings = 0
    build_results_data = []

    if !@build_results.nil?
      @build_results.each { |b|
        build_errors += 1 if b.is_error
        build_warnings += 1 if b.is_warning

        build_results_data << b.inspect
      }
    end

    json_data = {"build_results"=>build_results_data, "test_results"=>test_results_data}

    json_document = 
<<-eos
---
title: #{build_base_name}
tags: data
layout: ci_results
date: #{DateTime.now.utc.strftime("%F %T")}
build_error_count: #{build_errors}
build_warning_count: #{build_warnings}
test_count: #{test_results_total}
test_passed_count: #{test_results_passed}
repository: #{@repository}
compiler: #{@config.compiler}
compiler_version: #{@config.compiler_version}
architecture: #{@config.architecture}
os: #{@config.os}
os_distribution: #{@config.os_distribution}
is_release: #{is_release}
release_packaged: #{!@package_location.nil?}
tag_name: #{@tag_name}
commit_sha: #{@commit_sha}
branch_name: #{@branch_name}
test_run: #{!@test_results.nil?}
pull_request_issue_id: "#{pull_request_issue_id}"
pull_request_base_repository: #{@pull_request_base_repository}
pull_request_base_ref: #{@pull_request_base_ref}
device_id: #{device_id}
---

#{json_data.to_json}

eos


    begin
      response = @client.create_contents(@config.results_repository,
                                         "#{@config.results_path}/#{dateprefix}-#{results_file_name}",
                                         "Commit build results file: #{dateprefix}-#{results_file_name}",
                                         json_document)
    rescue => e
      @logger.error "Error creating contents file: #{e}"
    end

    if !@package_location.nil?
      @client.upload_asset(@release_url, @package_location, :content_type=>"application/x-deb", :name=>Pathname.new(@package_location).basename.to_s)
    end
  end

end

class Build
  def initialize(config)
    @config = config
    @client = Octokit::Client.new(:access_token=>config.token)
    @user = @client.user
    @user.login
    @potential_builds = []

    @config.repository_name = @client.repo(@config.repository).name
  end

  def query_releases
    releases = @client.releases(@config.repository)

    releases.each { |r| 
      @potential_builds << PotentialBuild.new(@client, @config, @config.repository, r.tag_name, nil, nil, r.url, r.releases, nil, nil, nil)
    }
  end

  def query_branches
    branches = @client.branches(@config.repository)

    branches.each { |b| 
      @potential_builds << PotentialBuild.new(@client, @config, @config.repository, nil, b.commit.sha, b.name, nil, nil, nil, nil, nil)
    }
  end

  def query_pull_requests
    pull_requests = @client.pull_requests(@config.repository, :state=>"open")

    pull_requests.each { |p| 
      @potential_builds << PotentialBuild.new(@client, @config, p.head.repo.full_name, nil, p.head.sha, p.head.ref, nil, nil, p.number, p.base.repo.full_name, p.base.ref)
    }
  end

  def filter_potential_builds

    begin
      files = @client.content @config.results_repository, :path=>@config.results_path

      file_names = []
      files.each { |f|
        file_names << f.name
      }

      @potential_builds.each { |p|
        p.filter_build file_names
      }
    rescue => e
      # there was an error getting the file list, no big deal (I think), _posts might not exist yet
    end

  end

  def potential_builds
    @potential_builds
  end

end

b = Build.new(Configuration.new("d2a821665446e86f90b15fc57d50d7a5a202247f", "ChaiScript/chaiscript-build-results", "_posts", "lefticus/cpp_project_with_errors", "gcc", "4.8.1", "x86_64", "Linux", "ubuntu"))

b.query_releases
b.query_branches
b.query_pull_requests

#b.potential_builds.each { |p|
#  puts p.inspect
#}

# b.filter_potential_builds

b.potential_builds.each { |p|
  p.do_package
  p.do_test
  p.post_results
}

