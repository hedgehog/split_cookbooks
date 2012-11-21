require 'rubygems'
require 'bundler'
Bundler.require
require 'yaml'
require 'base64'
require 'rake/clean'
require 'pry'

# split_cookbooks helper methods
require './metadata.rb'
require './helper.rb'

load './deploy_archives.rake'

def cookbook_list(manifest='upstream/oc_-_opscode_-_cookbooks.yml', scope='all')
  $stdout.puts "Starting build cookbook tasks: #{manifest}"
  upstream_cookbook_list(manifest, scope)
  @cookbook_list.collect do |k, v|
    puts cookbook = k
    puts replaces = v
    if @folder
      cookbook_path = File.join(Rake.original_dir, 'cookbooks', @folder, cookbook)
    else
      cookbook_path = File.join(Rake.original_dir, 'cookbooks', cookbook)
    end
    puts "Looking for: #{cookbook_path}"
    if File.directory?(cookbook_path)
      $stdout.puts "  Build Rake task: tmp/#{@abreviation}-#{cookbook}"
      puts "#{Rake.original_dir}/tmp/#{@abreviation}-#{cookbook}"
      puts File.directory?("#{Rake.original_dir}/tmp/#{@abreviation}-#{cookbook}").inspect

      create_repo(cookbook) unless repo_exists?(cookbook)
      create_team(cookbook)
      unless File.directory?("#{Rake.original_dir}/tmp/#{@abreviation}-#{cookbook}")

        file "tmp/#{@abreviation}-#{cookbook}" do
          $stdout.puts "  Cloning #{cookbook}"
          if @singles
            git "clone --quiet --no-hardlinks cookbooks/#{cookbook} tmp/#{@abreviation}-#{cookbook}"
          else
            git "clone --quiet --no-hardlinks cookbooks tmp/#{@abreviation}-#{cookbook}"
          end
          tmp_ckbk_dir = "#{Rake.original_dir}/tmp/#{@abreviation}-#{cookbook}"
          puts File.directory?(tmp_ckbk_dir)
          Dir.chdir(tmp_ckbk_dir) do
            $stdout.puts `pwd`
            $stdout.puts "  Extracting #{cookbook}"
            if @singles
            else
              if @folder
                git "filter-branch --subdirectory-filter #{@folder}/#{cookbook} HEAD -- --all"
              else
                git "filter-branch --subdirectory-filter #{cookbook} HEAD -- --all"
              end
            end
            git 'reset --hard'
            git 'reflog expire --expire=now --all'
            git 'repack -ad'
            git 'gc --aggressive --prune=now'

            # check for existing tags
            git 'remote rm origin'
            git "remote add cookbooks git@github.com:#{config['org']}/#{@abreviation}-#{cookbook}.git"
            git 'fetch cookbooks'

            # tag versions and archive tags
            revisions = git_output "--no-pager log --oneline --format='%H' master -- metadata.rb"
            version = nil
            revisions.split(/\n/).each do |rev|
              metadata = parse_metadata(cookbook, rev)
              if metadata['version'] && metadata['version'] != version
                version = metadata['version']
                puts "Now tagging #{rev} as qa-#{version}"
                git "tag -a qa-#{version}  -m 'Chef cookbook #{@abreviation}-#{cookbook} version: #{version}' #{rev}"
              else
                # puts "version: #{version} metadata['version']: #{metadata['version']}"
              end
            end
            git 'config --add remote.cookbooks.push "+refs/heads/*:refs/heads/*"'
            git 'config --add remote.cookbooks.push "+refs/tags/*:refs/tags/*"'
            git 'push cookbooks'
            result = `git ls-remote --heads cookbooks|grep refs/heads/qa`
            if $? == 0
              # TODO: Add re-base dry-run test and then dry run is it will be clean.
              #
            else
              puts 'Creating the qa branch.'
              git 'checkout -b qa'
              git 'push -u cookbooks qa'
            end
            Dir.chdir(Rake.original_dir) do
              puts `./archive_tags.sh #{tmp_ckbk_dir} #{@abreviation}-#{cookbook} /src/archives #{replaces}`
            end
          end
        end

      end

      puts "Execute rake task: tmp/#{@abreviation}-#{cookbook}"
      Rake::Task["tmp/#{@abreviation}-#{cookbook}"].execute
    end
    puts "Delete: #{cookbook_path}"
    FileUtils.rm_rf(cookbook_path)
  end.reject { |c| c.nil? }
end

def git(command)
  begin
    resp = system %{git #{command}}
  rescue => e
    puts e.inspect
    puts caller.join('/n')
  ensure
    #puts resp
    resp
  end
end

def git_output(command)
  `git #{command}`.chomp
end

def upstream_cookbook_list(manifest='upstream/oc_-_opscode_-_cookbooks.yml', scope='all')
  # Test if cookbook silo or single cookbook repositories.
  if @repository && !@singles
    $stdout.puts "Starting build collected cookbook list from manifest: #{manifest}"
    @cookbook_list = YAML.load_file(File.join(Rake.original_dir, manifest))
    unless scope == 'all'
      @cookbook_list = @cookbook_list.find_all{|ckbk| ckbk == scope}
    end
  else
    $stdout.puts "Starting build individual cookbook list from manifest: #{manifest}"
    @cookbook_list = YAML.load_file(File.join(Rake.original_dir, manifest))
    unless scope == 'all'
      @cookbook_list = @cookbook_list.find_all{|ckbk| ckbk == scope}
    end
  end
  puts "  Total cookbooks: #{@cookbook_list.size}"
  @cookbook_list
end

def post(uri, payload)
  sleep 1 # github api throttlin'
  headers = { 'Authorization' => "token #{config['token']}", :content_type => :json, :accept => :json}
  puts "URI: #{uri}"
  puts "JSON payload: #{payload.to_json}"
  puts "Headers: #{headers}"
  begin
  json_response = RestClient.post(uri, payload.to_json, headers)
  rescue RestClient::UnprocessableEntity => e
    # we ignore cases where the team already exists.  We are expected to delete
    #repos we want to create but not teams.
    raise(e) unless e.message[/422 Unprocessable Entity/]
  rescue => err
    $stdout.puts "Error: #{err}"
    $stdout.puts "Error: #{err.inspect}"
    $stdout.puts "Error: #{err.message}"
    $stdout.puts "Error: #{json_response.inspect}"
  ensure
    puts "Respone: #{json_response.inspect}"
  end
  json_response.nil? ? "{}".to_json : JSON.parse(json_response)
end

def get(uri)
  sleep 1 # github api throttlin'
  headers = { 'Authorization' => "token #{config['token']}"}
  JSON.parse(RestClient.get(uri, headers))
end

def upstream_clone
  Dir.chdir(Rake.original_dir) do |path|
    if @repository
      puts "  Cloning upstream #{@upstream}/#{@repository}.git to cookbooks"
      git "clone --verbose --progress git://github.com/#{@upstream}/#{@repository}.git cookbooks"
    else
      @repositories.each do |repo|
        puts "  Cloning upstream #{@upstream}/#{repo}.git to cookbooks/#{repo}"
        git "clone --verbose --progress git://github.com/#{@upstream}/#{repo}.git cookbooks/#{repo}"
      end
    end
  end
end

def cleanup_clone
  Dir.chdir(Rake.original_dir) do |path|
    FileUtils.rm_rf('cookbooks') if Dir.exist?('cookbooks')
  end
  @deep_clone = nil
end

def create_team(name)
  create_team_uri = "https://api.github.com/orgs/#{config['org']}/teams"
  sleep 1
  team_info = {:name => "#{@abreviation}-#{name}", :permission => 'push', :repo_names => ["#{config['org']}/#{@abreviation}-#{name}"]}
  create_team_result = post create_team_uri, team_info
  puts "  Team creation succeeded: #{create_team_result.inspect}"
  sleep 1
  team_info2 = {:name => "#{name}", :permission => 'push', :repo_names => ["#{config['org']}/#{@abreviation}-#{name}"]}
  create_team2_result = post create_team_uri, team_info2
  puts "  Team 2 creation succeeded: #{create_team2_result.inspect}"
  # team_id = create_team_result['team']['id']
  # add_team_member_uri = "https://github.com/api/v2/json/teams/#{team_id}/members?name=#{config['login']}"
  # add_team_member_result = post add_team_member_uri
  # puts add_team_member_result.inspect
  create_team2_result
end

def create_repo(name)
  repo_info = {
    :public      => 1,
    :name        => "#{@abreviation}-#{name}",
    :description => "A Chef cookbook for #{name} (Initial Upstream: #{@upstream}, Repository: #{@repository||name})",
    :homepage    => "https://github.com/#{@upstream}/#{@repository||name}"
  }
  puts "Creating repo: #{repo_info[:name]}"
  create_repo_uri = "https://api.github.com/orgs/#{config['org']}/repos"
  create_repo_result = post create_repo_uri, repo_info
  puts "  Repo creation succeeded: #{create_repo_result.inspect}"
  create_repo_result
end

def repo_exists?(name)
  repo = true
  url = "https://api.github.com/repos/#{config['org']}/#{@abreviation}-#{name}"
  begin
    $stdout.puts "Checking URL: #{url}"
    repositories = get(url)
    $stdout.puts "  Check result: #{repositories.inspect}"
  rescue RestClient::ResourceNotFound => e
      repo = false
      $stdout.puts "  Other error: #{e.inspect}"
      $stdout.puts "  HTTP Code: #{e.http_code}"
  end
  repo
end

def parse_metadata(cookbook, rev)
  begin
    git "checkout #{rev}"
    if ::File.exist?('metadata.rb')
      #puts ::File.read('metadata.rb')
      `knife cookbook metadata from file metadata.rb`
    end
    if ::File.exist?('metadata.json')
      metadata= ::JSON.parse(::File.read('metadata.json'))
      # puts "Cookbook #{cookbook} Git revision #{rev} is version #{metadata['version']}"
      FileUtils.rm('metadata.json')
    else
      puts "No metadata.rb|json for Cookbook #{cookbook} Git revision #{rev}"
      metadata = {}
    end
    git "reset --hard -q"
  rescue
    puts "Failed to parse metadata.rb rev: #{rev}"
  end
  #puts "  metadata['version']=#{metadata['version']} for rev: #{rev}"
  metadata
end

def parse_manifest(manifest, single_repo=false)
  @folder = false
  if single_repo
    @abreviation, @upstream = manifest.sub(/^upstream\/singles\//, '').sub(/\.yml$/, '').split('_-_')
    @repository = false
    @repositories = YAML.load_file(File.join(Rake.original_dir, manifest)).keys
  else
    @repository = true
    ary = manifest.sub(/^upstream\//, '').sub(/\.yml$/, '').split('_-_')
    case ary.size
      when 3
        @abreviation, @upstream, @repository = ary
      when 4
        @abreviation, @upstream, @repository, @folder = ary
    end
  end
end

def update_single(cookbook)
  Rake::Task[:create_tasks].invoke(cookbook)
  puts "="*80
end

def update_all
  begin
    #TODO: Refactor to loop over a file glob of rake tasks in tmp folder.
    $stdout.puts "Starting update all."
    Dir.chdir(Rake.original_dir) do |path|
      FileList["upstream/*.yml"].collect do |manifest|
        @singles = false
        $stdout.puts "Starting parse collected repository manifest: #{manifest}"
        parse_manifest(manifest)
        upstream_clone
        cookbook_list(manifest).each do |ckbk|
          $stdout.puts "  Starting update_all cookbooks collective update: #{ckbk[0].inspect}"
          update_single(ckbk[0])
        end
        cleanup_clone
      end
      FileList["upstream/singles/*.yml"].collect do |manifest|
        @singles = true
        $stdout.puts "Starting parse single repositories manifest: #{manifest}"
        parse_manifest(manifest, true)
        upstream_clone
        cookbook_list(manifest).each do |cookbook|
          $stdout.puts "  Starting update_all cookbooks singular update: #{cookbook[0].inspect}"
          update_single(cookbook[0])
        end
        cleanup_clone
      end
    end
  ensure
  end
end

task :clone_clean do
  cleanup_clone()
end

desc "Update all cookbooks in Opscode's Chef Cookbooks repository."
task :default do |tsk|
  begin
    update_all
  ensure
    CLEAN.include('tmp/*')
    Rake::Task['clone_clean'].invoke
    Rake::Task['clean'].invoke
    cleanup_clone()
  end
end

task :create_tasks, [:cookbook] do |tsk, args|
  args.with_defaults(:cookbook => 'all')
  cookbook=args[:cookbook]
  Dir.chdir(Rake.original_dir) do |path|
    FileList["upstream/*.yml"].collect do |manifest|
      $stdout.puts "Processing Cookbook manifest: #{manifest} "
      parse_manifest(manifest)
      upstream_clone unless Dir.exist? 'cookbooks'
    end
  end
end

desc "Update cookbooks (default: all) from <upstream> Chef Cookbooks repositories."
task :update, [:cookbook] => [:clone_clean] do |tsk, args|
  begin
    args.with_defaults(:cookbook => 'all')
    $stdout.puts "Starting update: #{args.inspect} "
    if args[:cookbook] == 'all'
      update_all
    else
      @single = true
      update_single(args[:cookbook])
    end
  ensure
    CLEAN.include('tmp/*')
    Rake::Task['clone_clean'].invoke
    Rake::Task['clean'].invoke
    cleanup_clone()
  end
end

#Dir.chdir(Rake.original_dir) do |path|
#  FileList["upstream/*.yml"].collect do |manifest|
#    $stdout.puts "Processing Cookbook manifest: #{manifest} "
#    cookbook_list(manifest, args[:cookbook])
#  end
#end
