require 'rubygems'
require 'bundler'
Bundler.require
require 'yaml'
require 'base64'
require 'rake/clean'

def cookbook_list(manifest='upstream/opscode_-_cookbooks.yml', scope='all')
  $stdout.puts "Starting build cookbook tasks: #{manifest}"
  upstream_cookbook_list(manifest, scope)
  @cookbook_list.collect do |cookbook|
    cookbook_path = File.join(Rake.original_dir, 'cookbooks', cookbook)
    if File.directory?(cookbook_path)
      $stdout.puts "  Build Rake task: tmp/#{cookbook}"

      file "tmp/#{cookbook}" do
        $stdout.puts "  Cloning #{cookbook}"
        git "clone --no-hardlinks cookbooks tmp/#{cookbook}"
        Dir.chdir("#{Rake.original_dir}/tmp/#{cookbook}") do
          puts `pwd`
          $stdout.puts "  Extracting #{cookbook}"
          git "filter-branch --subdirectory-filter #{cookbook} HEAD -- --all"
          git "reset --hard"
          git 'reflog expire --expire=now --all'
          git 'repack -ad'
          git "gc --aggressive --prune=now"

          create_repo(cookbook) unless repo_exists?(cookbook)

          # check for existing tags
          git "remote rm origin"
          git "remote add cookbooks git@github.com:#{config['org']}/#{cookbook}.git"
          git "fetch cookbooks"

          # tag versions
          revisions = git_output "rev-list --topo-order --branches"
          version = nil
          revisions.split(/\n/).each do |rev|
            metadata = parse_metadata(cookbook, rev)
            if metadata['version'] && metadata['version'] != version
              version = metadata['version']
              puts "tagging #{rev} as #{version}"
              git "tag -a #{version}  -m 'Chef cookbook #{cookbook} version: #{version}' #{rev}"
            end
          end
          git "push --tags cookbooks master"
        end

      end

      cookbook
    end
  end.reject { |c| c.nil? }
end

def git(command)
  system %{git #{command}}
end

def git_output(command)
  `git #{command}`.chomp
end

def config
  @config ||= YAML.load_file(File.join(Rake.original_dir, 'config.yml'))
end

def upstream_cookbook_list(manifest='upstream/opscode_-_cookbooks.yml', scope='all')
  $stdout.puts "Starting build cookbook list from manifest: #{manifest}"
  @cookbook_list = YAML.load_file(File.join(Rake.original_dir, manifest))
  unless scope == 'all'
    @cookbook_list = @cookbook_list.find_all{|ckbk| ckbk == scope}
  end
end

def post(uri, payload)
  sleep 1 # github api throttlin'
  basic_auth = Base64.encode64("#{config['login']}/token:#{config['token']}").gsub("\n", '')
  headers = { 'Authorization' => "Basic #{basic_auth}", :content_type => :json, :accept => :json}
  JSON.parse(RestClient.post(uri, payload.to_json, headers))
end

def get(uri)
  sleep 1 # github api throttlin'
  basic_auth = Base64.encode64("#{config['login']}/token:#{config['token']}").gsub("\n", '')
  headers = { 'Authorization' => "Basic #{basic_auth}"}
  JSON.parse(RestClient.get(uri, headers))
end

def upstream_clone
  Dir.chdir(Rake.original_dir) do |path|
    git "clone --verbose --progress git://github.com/#{@upstream}/#{@repository}.git cookbooks"
  end
end

def cleanup_clone
  Dir.chdir(Rake.original_dir) do |path|
    FileUtils.rm_rf('cookbooks') if Dir.exist?('cookbooks')
  end
  @deep_clone = nil
end

def create_repo(name)
  repo_info = {
    :public      => 1,
    :name        => "#{config['org']}/#{name}",
    :description => "A Chef cookbook for #{name} (Initial Upstream: #{@upstream}, Repository: #{@repository})",
    :homepage    => "https://github.com/opscode/cookbooks/blob/master/LICENSE"
  }
  post "https://github.com/api/v2/json/repos/create", repo_info
  post "https://github.com/api/v2/json/teams/#{config['team_id']}/repositories", {:name => "#{config['org']}/#{name}"}
end

def repo_exists?(name)
  repositories = get("https://github.com/api/v2/json/organizations/repositories")
  repositories['repositories'].detect { |r| r["name"] == name }
end

def parse_metadata(cookbook, rev)
  begin
    metadata = JSON.parse(git_output("show #{rev}:metadata.json"))
  rescue
    git "reset -q #{rev} metadata.rb"
    `knife cookbook metadata from file metadata.rb`
    metadata= JSON.parse(::File.read('metadata.json'))
    puts "Cookbook #{cookbook} Git revision #{rev} is version #{metadata['version']}"
    rm('metadata.json')
    git "reset --hard -q"
  end
  metadata
end

def parse_manifest(manifest)
  @upstream, @repository = manifest.sub(/^upstream\//, '').sub(/\.yml$/, '').split('_-_')
end

def update_single(cookbook)
  Rake::Task[:create_tasks].invoke(cookbook)
  Rake::Task["tmp/#{cookbook}"].invoke
end

def update_all
  begin
    #TODO: Refactor to loop over a file glob of rake tasks in tmp folder.
    $stdout.puts "Starting update all."
    Dir.chdir(Rake.original_dir) do |path|
      FileList["upstream/*.yml"].collect do |manifest|
        $stdout.puts "Starting parse manifest: #{manifest}"
        parse_manifest(manifest)
        upstream_clone
        cookbook_list(manifest).each do |cookbook|
          $stdout.puts "  Starting update: #{cookbook}"
          update_single(cookbook)
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
  end
end

task :create_tasks, [:cookbook] do |tsk, args|
  args.with_defaults(:cookbook => 'all')
  Dir.chdir(Rake.original_dir) do |path|
    FileList["upstream/*.yml"].collect do |manifest|
      $stdout.puts "Processing Cookbook manifest: #{manifest} "
      parse_manifest(manifest)
      upstream_clone unless Dir.exist? 'cookbooks'
      cookbook_list(manifest, args[:cookbook])
    end
  end
end

desc "Update specific cookbook (default: all) from Opscode's Chef Cookbooks repository."
task :update, [:cookbook] => [:clone_clean] do |tsk, args|
  begin
    args.with_defaults(:cookbook => 'all')
    $stdout.puts "Starting update: #{args.inspect} "
    if args[:cookbook] == 'all'
      update_all
    else
      update_single(args[:cookbook])
    end
  ensure
    CLEAN.include('tmp/*')
    Rake::Task['clone_clean'].invoke
    Rake::Task['clean'].invoke
    cleanup_clone()
  end
end

cookbook_list
